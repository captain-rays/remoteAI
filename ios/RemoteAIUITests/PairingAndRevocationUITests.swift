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
        let revoke = app.descendants(matching: .any)
            .matching(identifier: "revoke-device").firstMatch
        for _ in 0..<3 where !revoke.exists {
            app.swipeUp()
        }
        XCTAssertTrue(revoke.waitForExistence(timeout: 5))
        revoke.tap()

        XCTAssertTrue(app.buttons["Revoke"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["revoke-device"].exists)
    }

    func testApprovalOffersOnlyAllowOnceAndDeny() {
        let app = launchApp()
        let dailyChat = app.descendants(matching: .any)
            .matching(identifier: "Shell one-liners").firstMatch
        XCTAssertTrue(dailyChat.waitForExistence(timeout: 5))
        dailyChat.tap()

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField from
        // legacy attributes and a TextView from modern ones, so neither typed
        // query matches reliably. Address the composer by identifier instead.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("please run something that needs approval")
        app.buttons["send"].tap()

        let approvalCard = app.descendants(matching: .any)
            .matching(identifier: "approval-card").firstMatch
        XCTAssertTrue(approvalCard.waitForExistence(timeout: 10))
        let allowOnce = app.descendants(matching: .any)
            .matching(identifier: "approval-allow_once").firstMatch
        let deny = app.descendants(matching: .any)
            .matching(identifier: "approval-deny").firstMatch
        XCTAssertTrue(allowOnce.waitForExistence(timeout: 5))
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "approval-always").firstMatch.exists,
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
