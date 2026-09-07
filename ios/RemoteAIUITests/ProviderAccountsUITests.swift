import XCTest

/// The accounts screen, driven the way a person would: from the tab bar, with
/// the mock agent standing in for the Mac.
final class ProviderAccountsUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        app.launch()
        return app
    }

    /// Addresses a SwiftUI text field by identifier. Xcode 26 classifies a
    /// vertical `TextField` as a TextField from legacy attributes and a
    /// TextView from modern ones, so neither typed query matches reliably.
    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        element(identifier, in: app)
    }

    /// Addresses an element by identifier without asserting its type.
    ///
    /// SwiftUI's mapping onto XCUIElementType is not stable across OS
    /// versions — a `Link` can arrive as a button, a `LabeledContent` as
    /// static text — and a typed query that guesses wrong reports the element
    /// as missing.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(200_000)
        }
        return !element.exists
    }

    private func openAccounts(_ app: XCUIApplication, provider: String) {
        app.tabBars.buttons["Settings"].tap()
        let link = app.buttons["accounts-\(provider)"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
    }

    func testTheAccountInUseIsNamedAndTheSavedOnesListed() {
        let app = launchApp()
        openAccounts(app, provider: "codex")

        let current = element("current-account", in: app)
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertTrue(
            current.label.contains("work@example.com"),
            "the account in use is named, not just counted: \(current.label)"
        )
        XCTAssertTrue(element("account-work", in: app).waitForExistence(timeout: 5))
    }

    func testSavingTheCurrentSignInAddsAnAccountThatCanBeSwitchedTo() {
        let app = launchApp()
        openAccounts(app, provider: "codex")

        let label = field("new-account-label", in: app)
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        label.tap()
        label.typeText("personal")
        app.buttons["save-account"].tap()

        XCTAssertTrue(element("account-personal", in: app).waitForExistence(timeout: 10))

        // The account just saved is the one in use, so the *other* one is what
        // can be switched to.
        let use = app.buttons["use-account-work"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        use.tap()

        XCTAssertTrue(app.buttons["use-account-personal"].waitForExistence(timeout: 10))
    }

    func testSigningInShowsTheLinkAndCodeAndCompletesWithTheEnteredCode() {
        let app = launchApp()
        openAccounts(app, provider: "claude")

        app.buttons["sign-in"].tap()
        let start = app.buttons["start-sign-in"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        let saveAs = field("sign-in-label", in: app)
        saveAs.tap()
        saveAs.typeText("phone")
        start.tap()

        // What the Mac printed reaches the phone: a link, a code, a prompt.
        XCTAssertTrue(element("sign-in-url", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("sign-in-user-code", in: app).exists)

        let code = field("sign-in-code", in: app)
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("123456")
        app.buttons["send-code"].tap()

        // The sheet closes on its own when the Mac says the flow is over.
        let sheetField = field("sign-in-code", in: app)
        XCTAssertTrue(
            waitForDisappearance(of: sheetField, timeout: 15),
            "the sign-in sheet closes itself once the Mac reports the outcome"
        )
        let current = element("current-account", in: app)
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertTrue(
            current.label.contains("mock@example.com"),
            "the new account is the one in use: \(current.label)"
        )
        XCTAssertTrue(element("account-phone", in: app).waitForExistence(timeout: 10))
    }

    func testARejectedCodeIsReportedInsteadOfSilentlyFailing() {
        let app = launchApp()
        openAccounts(app, provider: "claude")

        app.buttons["sign-in"].tap()
        let start = app.buttons["start-sign-in"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let code = field("sign-in-code", in: app)
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("000000")
        app.buttons["send-code"].tap()

        let failure = app.staticTexts["sign-in-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertEqual(failure.label, "That code was rejected")
    }
}
