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

        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Reply with exactly: PONG. Do not use any tools.")
        app.buttons["send"].tap()

        let reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "PONG")
        ).firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 180),
            "no assistant reply arrived from Codex"
        )
    }
}
