import XCTest

/// A session started from the phone must end up in the project the user chose
/// and come back in that project's list — the Mac and the phone have to be
/// looking at the same session.
///
/// OPT-IN: needs a live agent and spends one small provider turn. The pairing
/// secret is single-use, so run this class on its own after restarting the
/// agent:
///
///     pkill -f remote-ai-agent
///     REMOTEAI_PAIRING_FILE="$HOME/Library/Application Support/RemoteAI/pairing.json" \
///       <agent binary> &
///     xcodebuild ... -only-testing:RemoteAIUITests/RealAgentSessionSyncUITests test
final class RealAgentSessionSyncUITests: XCTestCase {

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

    func testASessionStartedHereComesBackInTheProjectList() throws {
        let pairingFile = try XCTUnwrap(self.pairingFile, "no live agent configured")
        let app = XCUIApplication()
        app.launchArguments = [
            "-AgentPublicOrigin",
            ProcessInfo.processInfo.environment["REMOTEAI_AGENT_ORIGIN"]
                ?? "http://127.0.0.1:8787",
            "-RemoteAIPairingFile", pairingFile,
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pairing bootstrap: paired"].waitForExistence(timeout: 20))

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        app.tabBars.buttons["Projects"].tap()

        let project = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-row-"))
            .firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30))
        project.tap()

        let newSession = app.buttons["new-project-session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15))
        newSession.tap()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()

        // One real turn, so the provider writes the transcript that makes the
        // session real.
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Reply with one word.")
        app.buttons["send"].tap()
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
            .firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no reply arrived")

        // Back to the project. The list must pick the session up on its own —
        // this is the "I created it and it never showed up" report.
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let titled = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Reply with one word")
        ).firstMatch
        XCTAssertTrue(
            titled.waitForExistence(timeout: 30),
            "the project list never picked up the session started here"
        )
    }
}
