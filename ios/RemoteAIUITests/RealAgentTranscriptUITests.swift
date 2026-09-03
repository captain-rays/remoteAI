import XCTest

/// Reads a real, previously recorded provider transcript through a live Mac
/// agent and prints what the screen actually rendered.
///
/// OPT-IN, like `RealAgentConversationUITests`, and for the same reason: it
/// needs a live agent. It spends no provider quota — it only reads.
///
/// The agent's pairing secret is single-use, so run ONE class per agent start:
///
///     pkill -f remote-ai-agent
///     REMOTEAI_PAIRING_FILE="$HOME/Library/Application Support/RemoteAI/pairing.json" \
///       <agent binary> &
///     xcodebuild ... -only-testing:RemoteAIUITests/RealAgentTranscriptUITests test
final class RealAgentTranscriptUITests: XCTestCase {

    private var pairingFile: String? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["REMOTEAI_PAIRING_FILE"] {
            candidates.append(explicit)
        }
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

    /// Which provider to read. `REMOTEAI_UITEST_PROVIDER=Codex` switches it;
    /// xcodebuild does not forward env vars to the UI-test runner reliably, so
    /// the Codex run flips this default instead.
    private var provider: String {
        ProcessInfo.processInfo.environment["REMOTEAI_UITEST_PROVIDER"] ?? "Claude"
    }

    func testReadsARealProjectTranscript() throws {
        let pairingFile = try XCTUnwrap(
            self.pairingFile, "no live agent configured"
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
        XCTAssertTrue(app.staticTexts["Connection: online"].waitForExistence(timeout: 20))

        app.segmentedControls["provider-switcher"].buttons[provider].tap()
        app.tabBars.buttons["Projects"].tap()

        let project = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-row-"))
            .firstMatch
        XCTAssertTrue(
            project.waitForExistence(timeout: 30),
            "\(provider) reported no projects"
        )
        project.tap()

        let session = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(
            session.waitForExistence(timeout: 30),
            "the project reported no sessions"
        )
        session.tap()

        let anyMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "-message-"))
            .firstMatch
        XCTAssertTrue(
            anyMessage.waitForExistence(timeout: 60),
            "no transcript arrived for the opened session"
        )

        // What the screen actually shows, so the run can be inspected rather
        // than trusted.
        print("BEGIN_TRANSCRIPT\n\(app.debugDescription)\nEND_TRANSCRIPT")

        let users = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "user-message-"))
            .count
        let assistants = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
            .count
        print("TRANSCRIPT_COUNTS user=\(users) assistant=\(assistants)")
        XCTAssertGreaterThan(users + assistants, 0)
    }
}
