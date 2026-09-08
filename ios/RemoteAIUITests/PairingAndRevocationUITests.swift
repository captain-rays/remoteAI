import XCTest

/// Pairing, its failure modes, and revoking this device. Runs against the mock
/// agent, so it needs no Mac agent — only a simulator.
final class PairingAndRevocationUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        app.launch()
        return app
    }

    /// Tap a field and type once the keyboard is actually up.
    ///
    /// On the newer simulator runtimes the tap returns before focus lands, and
    /// `typeText` then fails with "neither element nor any descendant has
    /// keyboard focus" — a flake, not a product fault.
    private func type(_ app: XCUIApplication, _ text: String, into field: XCUIElement) {
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        }
        field.typeText(text)
    }

    func testExpiredPairingCodeIsRejected() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["start-pairing"].tap()

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField
        // from legacy attributes and a TextView from modern ones, so neither
        // typed query matches reliably. Address it by identifier instead.
        let field = app.descendants(matching: .any)
            .matching(identifier: "pairing-paste-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        type(app, Self.expiredPairingCode, into: field)
        app.buttons["pairing-submit"].tap()

        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 5))
    }

    func testUnreadableCodeIsRejectedWithoutCrashing() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["start-pairing"].tap()

        // Xcode 26 classifies a vertical SwiftUI TextField as a TextField
        // from legacy attributes and a TextView from modern ones, so neither
        // typed query matches reliably. Address it by identifier instead.
        let field = app.descendants(matching: .any)
            .matching(identifier: "pairing-paste-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        type(app, "not a pairing code", into: field)
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

        // A confirmationDialog is not an Alert in the accessibility tree, so
        // the button is addressed by the identifier the view gives it. On this
        // size class the dialog is a popover, which carries no Cancel button
        // of its own and is dismissed by tapping outside it.
        let confirm = app.descendants(matching: .any)
            .matching(identifier: "revoke-device-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertFalse(confirm.waitForExistence(timeout: 2), "the dialog stayed up")
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
