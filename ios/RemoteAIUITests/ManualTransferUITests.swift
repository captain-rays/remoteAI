import XCTest

/// NOT RUN on this Mac: XCUITest needs a simulator, which requires full Xcode.
final class ManualTransferUITests: XCTestCase {

    private func launchApp(useFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        if useFixture {
            app.launchArguments.append("-UITestMockDocumentPicker")
        }
        app.launch()
        return app
    }

    /// The permanent regression test for "no automatic synchronisation".
    func testIdleAppNeverStartsATransfer() {
        let app = launchApp()
        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.buttons["upload-button"].waitForExistence(timeout: 5))

        // Sit still, then leave and come back: neither may move a byte.
        Thread.sleep(forTimeInterval: 5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        Thread.sleep(forTimeInterval: 3)

        XCTAssertFalse(
            app.staticTexts.containing(
                NSPredicate(format: "identifier BEGINSWITH %@", "transfer-")
            ).element.exists,
            "no transfer row may appear without a user action"
        )
    }

    func testDownloadRequiresAnExplicitTap() {
        let app = launchApp()
        app.tabBars.buttons["Files"].tap()
        app.buttons["open-work"].tap()
        app.buttons["open-api"].tap()

        let transfer = app.descendants(matching: .any).matching(identifier: "transfer-local-1").firstMatch
        XCTAssertFalse(transfer.exists)
        app.buttons["download-README.md"].tap()
        XCTAssertTrue(transfer.waitForExistence(timeout: 5))
    }

    func testSameNameUploadBlocksUntilAPolicyIsChosen() {
        let app = launchApp(useFixture: true)
        app.tabBars.buttons["Files"].tap()
        app.buttons["open-work"].tap()
        app.buttons["open-api"].tap()
        app.buttons["upload-button"].tap()
        let uploadTransfer = app.descendants(matching: .any)
            .matching(identifier: "transfer-local-1").firstMatch
        XCTAssertTrue(uploadTransfer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["needs a decision"].waitForExistence(timeout: 5))

        // The injected fixture keeps this test deterministic while preserving
        // the explicit upload-button tap required in production.
        XCTAssertTrue(app.staticTexts["A file with this name already exists"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["conflict-keep-both"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["conflict-overwrite"].exists)
        XCTAssertTrue(
            app.buttons["conflict-cancel"].exists,
            "the user must be able to abandon the upload"
        )
    }

    func testHiddenFoldersNeedAConfirmation() {
        let app = launchApp()
        app.tabBars.buttons["Files"].tap()
        app.buttons["toggle-hidden"].tap()

        XCTAssertTrue(app.buttons["Show them"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts[".ssh"].exists)
    }
}
