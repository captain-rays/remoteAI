import XCTest

/// Acceptance coverage for the synchronized transcript: history that is loaded
/// from the agent (not produced by this session), the shared rich renderer, and
/// the two blocking states a send can land in.
///
/// Every fixture comes from `MockAgentClient`, so these run without the Rust
/// agent and without a provider credential anywhere on the device.
final class ConversationUITests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openClaudeChat(_ app: XCUIApplication, row: String) {
        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        let chat = element(app, row)
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
    }

    private func type(_ app: XCUIApplication, _ text: String) {
        let composer = element(app, "composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(text)
    }

    // MARK: - Rendering

    func testClaudeHistoryRendersBoldCodeAndCollapsedReasoning() {
        let app = launchApp()
        openClaudeChat(app, row: "daily-row-claude-daily-1")

        // The user's own turn is part of the synchronized history, not just of
        // the turns this device sent.
        XCTAssertTrue(
            app.staticTexts["Plan the trip and show the parser."].waitForExistence(timeout: 5)
        )

        // `**parser**` must arrive as bold text, which means the asterisks are
        // gone from the rendered label.
        let prose = element(app, "transcript-prose-0")
        XCTAssertTrue(prose.exists)
        XCTAssertTrue(
            prose.label.hasPrefix("Here is the parser you asked for:"),
            "unexpected prose label: \(prose.label)"
        )

        // Fenced block: own container, language label, copy button.
        XCTAssertTrue(element(app, "code-block-1").exists)
        XCTAssertEqual(element(app, "code-language-1").label, "swift")
        let copy = app.buttons["copy-code-1"]
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(copy.isHittable)

        // Quoted line renders as secondary content rather than plain prose.
        XCTAssertTrue(element(app, "transcript-quote-2").exists)
    }

    func testReasoningStartsCollapsedAndExpandsOnTap() {
        let app = launchApp()
        openClaudeChat(app, row: "daily-row-claude-daily-1")

        let disclosure = element(app, "reasoning-disclosure-claude-seed-reason-1")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["Weighing two itineraries."].exists,
            "reasoning must be collapsed until the user asks for it"
        )

        disclosure.tap()
        XCTAssertTrue(
            app.staticTexts["Weighing two itineraries."].waitForExistence(timeout: 5)
        )
    }

    func testCodexProjectSessionRendersItsOwnHistory() {
        let app = launchApp()
        app.tabBars.buttons["Projects"].tap()
        element(app, "project-row-codex:/Users/dev/work/api").tap()

        let session = element(app, "project-session-codex-project-api-1")
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        XCTAssertTrue(app.staticTexts["Show the router table."].waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "code-language-1").label, "bash")
        XCTAssertFalse(
            app.staticTexts["Plan the trip and show the parser."].exists,
            "a Claude transcript must never appear inside a Codex session"
        )
    }

    // MARK: - Blocked sends

    func testBusySessionStaysReadableAndBlocksSend() {
        let app = launchApp()
        openClaudeChat(app, row: "daily-row-claude-daily-2")

        // Readable while another writer holds the session.
        XCTAssertTrue(
            app.staticTexts["Which book is next?"].waitForExistence(timeout: 5)
        )

        type(app, "add one more")
        app.buttons["send"].tap()

        XCTAssertTrue(
            app.staticTexts[
                "This conversation is active elsewhere. You can view its history, but cannot send."
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(element(app, "message-delivery-failed").exists)
        XCTAssertTrue(
            app.buttons["retry-send"].exists,
            "the unsent message must stay retryable instead of being dropped"
        )
    }

    func testFailedSendShowsRetryAndRecovers() {
        let app = launchApp()
        app.segmentedControls["provider-switcher"].buttons["Codex"].tap()
        let chat = element(app, "daily-row-codex-daily-2")
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()

        type(app, "fail once please")
        app.buttons["send"].tap()

        let failed = element(app, "message-delivery-failed")
        XCTAssertTrue(failed.waitForExistence(timeout: 5))

        let retry = app.buttons["retry-send"]
        XCTAssertTrue(retry.exists)
        retry.tap()

        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["retry-send"]
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [cleared], timeout: 5), .completed,
            "a successful retry must clear the unsent state"
        )

        // The retry reuses the same local message; it must not add a second
        // copy of the user's text.
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "fail once please")).count,
            1
        )
    }
}
