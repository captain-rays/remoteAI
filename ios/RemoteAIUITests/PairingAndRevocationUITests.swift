import XCTest

/// NOT RUN on this Mac: XCUITest needs a simulator, which requires full Xcode.
final class PairingAndRevocationUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        app.launch()
        return app
    }

    func testExpiredPairingCodeIsRejected() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["start-pairing"].tap()

        let field = app.textViews["pairing-paste-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(Self.expiredPairingCode)
        app.buttons["pairing-submit"].tap()

        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
    }

    func testUnreadableCodeIsRejectedWithoutCrashing() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["start-pairing"].tap()

        let field = app.textViews["pairing-paste-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("not a pairing code")
        app.buttons["pairing-submit"].tap()

        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testRevokingThisPhoneAsksForConfirmation() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["revoke-device"].tap()

        XCTAssertTrue(app.buttons["Revoke"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["revoke-device"].exists)
    }

    func testApprovalOffersOnlyAllowOnceAndDeny() {
        let app = launchApp()
        app.staticTexts["Shell one-liners"].firstMatch.tap()

        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("please run something that needs approval")
        app.buttons["send"].tap()

        XCTAssertTrue(app.otherElements["approval-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["approval-allow_once"].exists)
        XCTAssertTrue(app.buttons["approval-deny"].exists)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "approval-")
            ).count,
            2,
            "there must be no permanent-allow option"
        )
    }

    /// Expires at 2020-01-01, so it is always in the past.
    private static let expiredPairingCode = """
    {"origin":"https://example.invalid","macId":"mac-1",\
    "macPublicKey":"AA==","pairingSecret":"AA==",\
    "expiresAt":"2020-01-01T00:00:00Z"}
    """
}
