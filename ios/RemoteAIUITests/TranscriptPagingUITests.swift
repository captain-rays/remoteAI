import XCTest

/// Covers how a transcript opens and pages, against the in-process mock agent.
///
/// This one is not opt-in: it needs no live agent and spends no provider quota.
/// The mock seeds one conversation long enough to span several pages, so the
/// wiring — open at the newest end, fetch the page before it when the reader
/// scrolls up — is exercised deterministically.
final class TranscriptPagingUITests: XCTestCase {

    private func launchMockedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"]
        app.launch()
        return app
    }

    private func openLongMockConversation(_ app: XCUIApplication) -> XCUIElement {
        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        app.tabBars.buttons["Projects"].tap()

        // The seeded long conversation lives in the mock's API project.
        let project = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-row-"))
            .firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20), "the mock listed no projects")
        project.tap()

        let session = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 20), "the project listed no sessions")
        session.tap()

        let transcript = app.descendants(matching: .any)
            .matching(identifier: "transcript").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        return transcript
    }

    func testATranscriptOpensOnItsNewestTurns() throws {
        let app = launchMockedApp()
        _ = openLongMockConversation(app)

        // The newest exchange must be the one on screen. The oldest, which is
        // above the fold and outside the first page, must not be.
        let newest = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "answer 9")
        ).firstMatch
        XCTAssertTrue(
            newest.waitForExistence(timeout: 20),
            "a transcript must open on its newest turn"
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "question 1"))
                .firstMatch.exists,
            "the oldest turn belongs to an earlier page and must not be loaded on open"
        )
    }

    func testScrollingUpLoadsTheEarlierTurns() throws {
        let app = launchMockedApp()
        let transcript = openLongMockConversation(app)

        let oldest = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "question 1")
        ).firstMatch
        XCTAssertFalse(oldest.exists, "the oldest turn starts out unloaded")

        // Scrolling towards the start of the conversation asks for the page
        // before the one on screen, repeatedly, until there is nothing earlier.
        for _ in 0..<12 where !oldest.exists {
            transcript.swipeDown()
        }

        XCTAssertTrue(
            oldest.waitForExistence(timeout: 10),
            "scrolling up must keep loading earlier turns until the "
                + "conversation starts"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "earlier-history")
                .firstMatch.exists,
            "once the oldest turn is loaded there is no earlier page to offer"
        )
    }
}
