import XCTest

/// Drives one real turn in the Codex **Chats** view against a locally running
/// Mac agent.
///
/// OPT-IN and skipped by `scripts/ios-check.sh`: it needs a live agent and
/// spends real provider quota. Run it on its own after restarting the agent,
/// because the pairing secret is single-use.
///
/// Run it *twice* to cover both write paths. The first run creates a throwaway
/// chat and writes to a thread the agent process already holds. The second run
/// reopens that throwaway against a freshly restarted agent, which is the path
/// that has to resume the thread before it can start a turn — `turn/start`
/// answers "thread not found" for a thread the running app-server has not
/// loaded. The test prints which path it took.
final class RealCodexChatUITests: XCTestCase {

    /// Title Codex reports for a thread that was never named. Every chat this
    /// test creates is one, so reopening one never touches a real conversation.
    private static let throwawayTitle = "Untitled Codex thread"

    private var pairingFile: String? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["REMOTEAI_PAIRING_FILE"] {
            candidates.append(explicit)
        }
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            candidates.append(hostHome + "/Library/Application Support/RemoteAI/pairing.json")
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    func testCompletesOneTurnInACodexChat() throws {
        try XCTSkipIf(pairingFile == nil, "no live agent configured")
        let pairingFile = try XCTUnwrap(self.pairingFile)

        let app = XCUIApplication()
        app.launchArguments = [
            "-AgentPublicOrigin",
            ProcessInfo.processInfo.environment["REMOTEAI_AGENT_ORIGIN"]
                ?? "http://127.0.0.1:8787",
            "-RemoteAIPairingFile", pairingFile,
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Pairing bootstrap: paired"].waitForExistence(timeout: 20),
            "never paired with the agent"
        )
        XCTAssertTrue(app.staticTexts["Connection: online"].waitForExistence(timeout: 20))

        app.segmentedControls["provider-switcher"].buttons["Codex"].tap()
        app.tabBars.buttons["Chat"].tap()

        // Codex Chats must be readable at all. An empty list here was the
        // symptom of the view requiring a host bridge nothing wires up.
        let anyChat = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
            .firstMatch
        XCTAssertTrue(
            anyChat.waitForExistence(timeout: 30),
            "the Codex Chats list was empty"
        )

        // Prefer a throwaway this test created on an earlier run: writing to it
        // is the resume-before-turn path. Otherwise create one.
        let existingThrowaway = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
            .containing(NSPredicate(format: "label CONTAINS %@", Self.throwawayTitle))
            .firstMatch
        let reopened = existingThrowaway.exists
        if reopened {
            print("CODEX_CHAT_PATH reopened-existing-thread")
            existingThrowaway.tap()
        } else {
            print("CODEX_CHAT_PATH created-new-thread")
            let newChat = app.buttons["new-daily-chat"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 15))
            newChat.tap()
            let created = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
                .firstMatch
            XCTAssertTrue(created.waitForExistence(timeout: 30), "no Codex chat was created")
            created.tap()
        }

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField from
        // legacy attributes and a TextView from modern ones, so neither typed
        // query matches reliably. Address the composer by identifier instead.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Reply with exactly: PONG. Do not use any tools.")

        // Snapshot the transcript before the write. Reopening a session loads
        // its history, so "an assistant bubble exists" would pass on a reply
        // from an earlier run; the write has to produce something new.
        let assistantBubbles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        let baseline = assistantBubbles.count

        let send = app.buttons["send"]
        XCTAssertTrue(send.isEnabled, "the composer refused to enable send")
        send.tap()
        // A refusal the provider itself reports is a real outcome the phone
        // must show, and it is matched by its wording so an unrelated error
        // cannot stand in for the turn resolving.
        let refusal = app.staticTexts.containing(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "turn_failed", "usage limit"
            )
        ).firstMatch

        let resolved = expectation(description: "the Codex chat turn resolves visibly")
        let deadline = Date().addingTimeInterval(180)
        DispatchQueue.global().async {
            while Date() < deadline {
                if assistantBubbles.count > baseline || refusal.exists {
                    resolved.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        wait(for: [resolved], timeout: 190)

        let transcript = app.descendants(matching: .staticText)
            .allElementsBoundByIndex
            .map(\.label)
            .joined(separator: " | ")
        // Silence is the bug: the message left the phone and nothing ever came
        // back, with no reason shown.
        XCTAssertTrue(
            assistantBubbles.count > baseline || refusal.exists,
            "the Codex chat turn produced neither an answer nor a reason: \(transcript)"
        )
        // "session_busy" or a rejected send would mean the write never reached
        // the provider at all, which is a different failure from a refusal.
        for blocker in ["session_busy", "provider_unavailable", "message not sent"] {
            XCTAssertFalse(
                transcript.localizedCaseInsensitiveContains(blocker),
                "the write never reached Codex (\(blocker)): \(transcript)"
            )
        }
        print(
            "CODEX_CHAT_OUTCOME assistant bubbles \(baseline) -> \(assistantBubbles.count) :: "
                + transcript
        )
    }
}
