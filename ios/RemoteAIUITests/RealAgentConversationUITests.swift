import XCTest

/// Drives one real conversation against a locally running Mac agent.
///
/// OPT-IN. Every test here skips unless `REMOTEAI_PAIRING_FILE` is set, because
/// it needs a live agent and it spends real provider quota. Run it with:
///
///     pkill -f remote-ai-agent
///     REMOTEAI_PAIRING_FILE=/tmp/pairing.json <agent binary> &
///     xcodebuild ... \
///       TEST_RUNNER_REMOTEAI_PAIRING_FILE=/tmp/pairing.json \
///       -only-testing:RemoteAIUITests/RealAgentConversationUITests test
///
/// The pairing secret is single-use, so the agent must be restarted (which
/// re-issues it) before each run.
final class RealAgentConversationUITests: XCTestCase {

    /// Presence of the agent's pairing file is what opts these tests in;
    /// `xcodebuild`'s `TEST_RUNNER_` forwarding does not reach the UI-test
    /// runner reliably.
    ///
    /// The default is the agent's own state directory, which is owner-only —
    /// the agent refuses to write a one-time secret anywhere group- or
    /// world-accessible, so a path under /tmp is not an option.
    private var pairingFile: String? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["REMOTEAI_PAIRING_FILE"] {
            candidates.append(explicit)
        }
        // Set by the simulator for processes it hosts; lets the runner reach
        // the Mac's home directory rather than its own container.
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            candidates.append(
                hostHome + "/Library/Application Support/RemoteAI/pairing.json"
            )
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    private var origin: String {
        ProcessInfo.processInfo.environment["REMOTEAI_AGENT_ORIGIN"] ?? "http://127.0.0.1:8787"
    }

    private func launchPairedApp() throws -> XCUIApplication {
        let pairingFile = try XCTUnwrap(
            self.pairingFile, "set REMOTEAI_PAIRING_FILE to run the real-agent tests"
        )
        let app = XCUIApplication()
        app.launchArguments = [
            "-AgentPublicOrigin", origin,
            "-RemoteAIPairingFile", pairingFile,
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Pairing bootstrap: paired"].waitForExistence(timeout: 20),
            "the app never paired with the agent"
        )
        return app
    }

    /// One test, deliberately: the agent's pairing secret is single-use, so a
    /// second test in the same run cannot pair. Pairing is asserted inside
    /// `launchPairedApp`, so this one case covers the whole path.
    func testSendsOneMessageToClaudeAndReceivesAReply() throws {
        try XCTSkipIf(pairingFile == nil, "no live agent configured")
        let app = try launchPairedApp()
        XCTAssertTrue(app.staticTexts["Connection: online"].waitForExistence(timeout: 20))

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()

        let newChat = app.buttons["new-daily-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        newChat.tap()

        // The new session appears in the list; open it.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "daily-row-"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Claude session was created")
        row.tap()

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField from
        // legacy attributes and a TextView from modern ones, so neither typed
        // query matches reliably. Address the composer by identifier instead.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("What is 2+2? Answer with one word.")
        app.buttons["send"].tap()

        // Assert on an assistant bubble, not on text: the prompt itself would
        // match any token we asked the model to echo.
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
            .firstMatch
        // A real turn goes out to the provider, so allow a generous window.
        XCTAssertTrue(
            reply.waitForExistence(timeout: 120),
            "no assistant reply arrived from Claude"
        )
        print("ASSISTANT_REPLY \(reply.debugDescription)")
    }
}
