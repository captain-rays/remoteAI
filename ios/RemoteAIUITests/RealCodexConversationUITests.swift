import XCTest

/// Drives one real Codex turn against a locally running Mac agent.
///
/// OPT-IN and skipped by `scripts/ios-check.sh`: it needs a live agent and
/// spends real provider quota. Run it on its own after restarting the agent,
/// because the pairing secret is single-use.
///
/// It creates a *new* session inside a project rather than resuming an existing
/// one, so it never appends to a transcript the user cares about.
final class RealCodexConversationUITests: XCTestCase {

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

    func testReadsCodexProjectsAndCompletesOneTurn() throws {
        try XCTSkipIf(pairingFile == nil, "no live agent configured")
        let pairingFile = try XCTUnwrap(self.pairingFile)

        let app = XCUIApplication()
        app.launchArguments = [
            "-AgentPublicOrigin", "http://127.0.0.1:8787",
            "-RemoteAIPairingFile", pairingFile,
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Pairing bootstrap: paired"].waitForExistence(timeout: 20),
            "never paired with the agent"
        )

        app.segmentedControls["provider-switcher"].buttons["Codex"].tap()
        app.tabBars.buttons["Projects"].tap()

        // 1. Session reading: the agent must index real Codex projects.
        let firstProject = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-row-"))
            .firstMatch
        XCTAssertTrue(
            firstProject.waitForExistence(timeout: 20),
            "no Codex projects were indexed"
        )
        firstProject.tap()

        // 2. That project must list its own sessions.
        let existingSession = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(
            existingSession.waitForExistence(timeout: 20),
            "the project listed no Codex sessions"
        )

        // 3. Conversation: start a fresh session so no real transcript is touched.
        let newSession = app.buttons["new-project-session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()

        let sessionRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 30), "no session to open")
        sessionRow.tap()

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField from
        // legacy attributes and a TextView from modern ones, so neither typed
        // query matches reliably. Address the composer by identifier instead.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Reply with exactly: PONG. Do not use any tools.")
        // Assert on an assistant bubble, not on text: the prompt itself would
        // match any token we asked the model to echo, so a text search passes
        // on the user's own message even when nothing came back. Count them
        // before the write so the assertion requires a *new* one.
        let assistantBubbles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        let baseline = assistantBubbles.count
        app.buttons["send"].tap()
        // A refusal the provider itself reports — out of quota, for example —
        // is a real outcome the phone must show. Match its wording rather than
        // "any error row", so an unrelated failure elsewhere in the screen
        // cannot stand in for the turn resolving.
        let refusal = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "turn_failed", "usage limit")
        ).firstMatch

        // A turn must always resolve visibly. Silence — the bug this covers —
        // is neither of these.
        let resolved = expectation(description: "the Codex turn resolves visibly")
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
        XCTAssertTrue(
            assistantBubbles.count > baseline || refusal.exists,
            "the Codex turn produced neither an answer nor a reason: \(transcript)"
        )
        XCTAssertFalse(
            transcript.contains("history_failed"),
            "opening a session started here must not report a history failure: \(transcript)"
        )
        if assistantBubbles.count > baseline {
            print("CODEX_ASSISTANT_REPLY bubbles \(baseline) -> \(assistantBubbles.count)")
        } else {
            print("CODEX_TURN_FAILED \(transcript)")
        }
    }
}
