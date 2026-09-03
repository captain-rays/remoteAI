import XCTest

/// Written against the mock agent's fixed fixtures, so they need no Rust agent.
/// Run by `scripts/ios-check.sh` whenever full Xcode and a simulator are
/// available.
final class ProviderSeparationUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        app.launch()
        return app
    }

    func testCodexIsSelectedOnFirstLaunch() {
        let app = launchApp()
        XCTAssertTrue(
            app.segmentedControls["provider-switcher"].buttons["Codex"].isSelected
        )
    }

    func testSwitchingToClaudeLeavesNoCodexRow() {
        let app = launchApp()

        let codexChat = app.descendants(matching: .any)
            .matching(identifier: "Shell one-liners").firstMatch
        XCTAssertTrue(codexChat.waitForExistence(timeout: 5))

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()

        let claudeChat = app.descendants(matching: .any)
            .matching(identifier: "Trip planning").firstMatch
        XCTAssertTrue(claudeChat.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "Shell one-liners").firstMatch.exists,
            "a Codex chat must not survive the switch to Claude"
        )
    }

    func testEachProviderHasItsOwnProjects() {
        let app = launchApp()
        app.tabBars.buttons["Projects"].tap()

        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "Fix hero layout").firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "api").firstMatch.waitForExistence(timeout: 5)
        )

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "notes").firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "site").firstMatch.exists,
            "the Codex-only project must not appear under Claude"
        )
    }

    func testProjectShowsOnlyItsOwnSessions() {
        let app = launchApp()
        app.tabBars.buttons["Projects"].tap()
        app.descendants(matching: .any).matching(identifier: "api").firstMatch.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "Refactor router").firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "Fix hero layout").firstMatch.exists,
            "another project's session must not appear here"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "Shell one-liners").firstMatch.exists,
            "a daily chat must not appear inside a project"
        )
    }

    func testDailyTabNeverShowsProjectSessions() {
        let app = launchApp()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "Shell one-liners").firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "Refactor router").firstMatch.exists
        )
    }
}
