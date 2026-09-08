import XCTest

/// The composer's voice mode, driven against the mock agent — whose
/// transcriber recites a sentence instead of listening, so the whole path is
/// exercisable without a microphone or a speech account.
final class VoiceComposerUITests: XCTestCase {

    private func openFirstChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
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

    func testTheComposerStartsOnTheKeyboardWithAVoiceButtonBesideIt() {
        let app = openFirstChat()
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["use-voice"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "hold-to-talk").firstMatch.exists,
            "voice is opt-in, not the default"
        )
    }

    func testHoldingTheTalkButtonPutsWhatWasSaidInTheComposerRatherThanSendingIt() {
        // The deliberate part: this client drives Claude with permission
        // prompts bypassed, so a misheard instruction is one the Mac would
        // carry out. The reader reads it first.
        let app = openFirstChat()
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 15))
        app.buttons["use-voice"].tap()

        let hold = element("hold-to-talk", in: app)
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        // Press, let the transcript build, then release.
        hold.press(forDuration: 1.5)

        let composer = element("composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "the keyboard comes back")
        let typed = composer.value as? String ?? ""
        XCTAssertTrue(
            typed.contains("跑一下测试"),
            "what was dictated is waiting to be read, not gone: \(typed)"
        )
        // And nothing was sent: the transcript has no new outgoing message
        // carrying that text.
        XCTAssertFalse(
            app.staticTexts["跑一下测试，如果都过了就提交。"].exists,
            "releasing must not send"
        )
    }

    func testTheVoiceAndKeyboardButtonSwapsBackAndForth() {
        let app = openFirstChat()
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 15))

        app.buttons["use-voice"].tap()
        XCTAssertTrue(element("hold-to-talk", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["use-keyboard"].exists)

        app.buttons["use-keyboard"].tap()
        XCTAssertTrue(element("composer", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["use-voice"].exists)
    }
}
