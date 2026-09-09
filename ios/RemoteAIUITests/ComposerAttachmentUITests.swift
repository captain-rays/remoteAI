import XCTest

/// Attaching a file to a message, driven against the mock agent.
///
/// The system photo and document pickers run in another process, so the
/// picking itself is not driven here: `-UITestMockDocumentPicker` stands in
/// for the document picker exactly as it does for the file browser's upload
/// button. Everything after the pick — the chip, the upload, the send, and
/// what the transcript then shows — is the real path.
final class ComposerAttachmentUITests: XCTestCase {

    private func openFirstChat(withFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        if withFixture {
            app.launchArguments.append("-UITestMockDocumentPicker")
        }
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'daily-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testTheComposerOffersBothThePhotoLibraryAndTheFiles() {
        let app = openFirstChat()
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 15))

        app.buttons["attach-file"].tap()
        XCTAssertTrue(app.buttons["attach-from-photos"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["attach-from-files"].exists)
    }

    func testAnAttachedFileIsShownOnTheComposerAndNamedInTheMessage() {
        let app = openFirstChat(withFixture: true)
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 15))

        app.buttons["attach-file"].tap()
        app.buttons["attach-from-files"].tap()

        // The chip appears and settles: it names the file, so the reader can
        // see what is about to go with the message.
        let chip = element("attachment-README.md", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 15))

        element("composer", in: app).tap()
        element("composer", in: app).typeText("what is this")
        app.buttons["send"].tap()

        // The message went, and the transcript says what travelled with it.
        XCTAssertTrue(
            app.staticTexts["what is this"].waitForExistence(timeout: 15),
            "the message with an attachment was not sent"
        )
        XCTAssertTrue(
            element("sent-attachment-README.md", in: app).waitForExistence(timeout: 15),
            "the transcript does not show what was attached"
        )
        // And the composer is clear for the next message.
        XCTAssertFalse(chip.exists, "the attachment stayed on the composer after sending")
    }
}
