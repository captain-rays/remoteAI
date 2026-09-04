import XCTest

/// Writes to a Claude conversation that already existed on the Mac before this
/// agent process started.
///
/// OPT-IN and skipped by `scripts/ios-check.sh`: it needs a live agent and
/// spends real provider quota. Run it on its own after restarting the agent,
/// because the pairing secret is single-use.
///
/// Run it *twice*. The first run creates a throwaway chat and writes to a
/// session this agent process already holds open. The second run reopens that
/// throwaway against a freshly restarted agent, which is the path that has to
/// resume the CLI session before it can be written to at all. The test prints
/// which path it took.
final class RealClaudeChatWriteUITests: XCTestCase {

    /// Marker that makes this test's own throwaway chats recognizable, so
    /// reopening one never appends to a conversation the user cares about.
    private static let probe = "RemoteAI write probe. Reply with one word."

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

    func testWritesToAClaudeChatAndReceivesAReply() throws {
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

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        app.tabBars.buttons["Chat"].tap()

        let anyChat = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
            .firstMatch
        XCTAssertTrue(anyChat.waitForExistence(timeout: 30), "the Claude Chats list was empty")

        // A chat titled with this test's own probe was created by an earlier
        // run, so the agent process running now has never opened it. Writing
        // to it is the resume-before-write path.
        let existingProbe = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
            .containing(NSPredicate(format: "label CONTAINS %@", "RemoteAI write probe"))
            .firstMatch
        if existingProbe.exists {
            print("CLAUDE_CHAT_PATH reopened-existing-session")
            existingProbe.tap()
        } else {
            print("CLAUDE_CHAT_PATH created-new-session")
            let newChat = app.buttons["new-daily-chat"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 15))
            newChat.tap()
            let created = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
                .firstMatch
            XCTAssertTrue(created.waitForExistence(timeout: 30), "no Claude chat was created")
            created.tap()
        }

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField from
        // legacy attributes and a TextView from modern ones, so neither typed
        // query matches reliably. Address the composer by identifier instead.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(Self.probe)

        // Snapshot the transcript before the write so the assertion below can
        // require something new rather than something already on screen.
        let baseline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
            .count
        let send = app.buttons["send"]

        // Count the assistant bubbles the loaded history already shows, and
        // require a *new* one. Asserting that any assistant bubble exists
        // passes on the reply from a previous run when the session is reopened.
        let assistantBubbles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        XCTAssertTrue(send.isEnabled, "the composer refused to enable send")
        send.tap()

        let arrived = expectation(description: "a new assistant reply arrives")
        let deadline = Date().addingTimeInterval(180)
        DispatchQueue.global().async {
            while Date() < deadline {
                if assistantBubbles.count > baseline {
                    arrived.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        wait(for: [arrived], timeout: 190)
        XCTAssertGreaterThan(
            assistantBubbles.count, baseline,
            "no new assistant reply arrived: "
                + app.descendants(matching: .staticText)
                    .allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        )
        print("CLAUDE_CHAT_REPLY new assistant bubbles: \(baseline) -> \(assistantBubbles.count)")
    }
}
