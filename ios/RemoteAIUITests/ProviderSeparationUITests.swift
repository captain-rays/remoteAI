import XCTest

/// NOT RUN on this Mac: XCUITest needs a simulator, which requires full Xcode.
/// These are written against the mock agent's fixed fixtures so they are ready
/// for the integration lane.
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

        let codexChat = app.staticTexts["Shell one-liners"]
        XCTAssertTrue(codexChat.waitForExistence(timeout: 5))

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()

        XCTAssertTrue(app.staticTexts["Trip planning"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["Shell one-liners"].exists,
            "a Codex chat must not survive the switch to Claude"
        )
    }

    func testEachProviderHasItsOwnProjects() {
        let app = launchApp()
        app.tabBars.buttons["Projects"].tap()

        XCTAssertTrue(app.staticTexts["Fix hero layout"].waitForExistence(timeout: 5) == false)
        XCTAssertTrue(app.staticTexts["api"].waitForExistence(timeout: 5))

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        XCTAssertTrue(app.staticTexts["notes"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["site"].exists,
            "the Codex-only project must not appear under Claude"
        )
    }

    func testProjectShowsOnlyItsOwnSessions() {
        let app = launchApp()
        app.tabBars.buttons["Projects"].tap()
        app.staticTexts["api"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Refactor router"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["Fix hero layout"].exists,
            "another project's session must not appear here"
        )
        XCTAssertFalse(
            app.staticTexts["Shell one-liners"].exists,
            "a daily chat must not appear inside a project"
        )
    }

    func testDailyTabNeverShowsProjectSessions() {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["Shell one-liners"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Refactor router"].exists)
    }
}
