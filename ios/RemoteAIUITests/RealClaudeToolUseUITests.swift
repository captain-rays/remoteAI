import XCTest

/// Runs one command from the phone that the Mac's permission gate used to
/// refuse, against a locally running Mac agent.
///
/// OPT-IN and skipped by `scripts/ios-check.sh`: it needs a live agent and
/// spends real provider quota.
///
/// This is the "pull the latest code" report. Under `--permission-mode manual`
/// the CLI answered "This command requires approval" and emitted no
/// `control_request`, so nothing on the phone could approve it and the turn
/// died after several retries. The command here is read-only — listing a git
/// remote — but it is one of the calls that was refused.
final class RealClaudeToolUseUITests: XCTestCase {

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

    func testRunsAGitCommandThePermissionGateUsedToRefuse() throws {
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
        app.tabBars.buttons["Projects"].tap()

        let project = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-row-"))
            .firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 30), "no Claude projects were indexed")
        project.tap()

        // A fresh session, so no transcript the user cares about is touched.
        let newSession = app.buttons["new-project-session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 15))
        newSession.tap()
        let sessionRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 30), "no session to open")
        sessionRow.tap()

        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(
            "Use the Bash tool to run exactly: git remote -v"
                + " — then reply with the word DONE followed by the first remote name."
        )

        let assistantBubbles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        let before = Set(assistantBubbles.allElementsBoundByIndex.map(\.identifier))
        app.buttons["send"].tap()

        let arrived = expectation(description: "the turn resolves")
        let deadline = Date().addingTimeInterval(180)
        DispatchQueue.global().async {
            while Date() < deadline {
                let now = Set(assistantBubbles.allElementsBoundByIndex.map(\.identifier))
                if !now.subtracting(before).isEmpty { arrived.fulfill(); return }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        wait(for: [arrived], timeout: 190)

        let transcript = app.descendants(matching: .staticText)
            .allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        print("TOOL_USE_TRANSCRIPT \(transcript)")
        // The exact wording the gate used to return. Its absence is the fix.
        XCTAssertFalse(
            transcript.contains("requires approval"),
            "a command the phone asked for was refused for want of an approver: \(transcript)"
        )
        XCTAssertTrue(
            transcript.contains("DONE"),
            "the command did not run to completion: \(transcript)"
        )
    }
}
