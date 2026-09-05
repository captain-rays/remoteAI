import XCTest

/// Covers how a transcript opens and pages, against the in-process mock agent.
///
/// This one is not opt-in: it needs no live agent and spends no provider quota.
/// The mock seeds one conversation long enough to span several pages, so the
/// wiring — open at the newest end, fetch the page before it when the reader
/// scrolls up — is exercised deterministically.
final class TranscriptPagingUITests: XCTestCase {

    private func launchMockedApp(slowHistory: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UseMockAgent"] + (slowHistory ? ["-SlowHistory"] : [])
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
            NSPredicate(format: "label CONTAINS %@", "answer 20")
        ).firstMatch
        XCTAssertTrue(
            newest.waitForExistence(timeout: 20),
            "a transcript must open on its newest turn"
        )
        // The earlier-turns row is what says an earlier page exists and has
        // not been fetched. Asserting that the oldest turn is merely absent
        // from the screen would also pass when the whole transcript is loaded
        // and simply scrolled out of view.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "earlier-history")
                .firstMatch.exists,
            "the turns before this page must still be waiting to be fetched"
        )
    }

    func testScrollingUpLoadsTheEarlierTurns() throws {
        let app = launchMockedApp()
        let transcript = openLongMockConversation(app)

        // The mock's conversation is twenty exchanges and a page is five, so
        // the first turn is four pages back. Match its label exactly: a
        // "contains" match would also hit "question 19".
        let oldest = app.staticTexts.containing(
            NSPredicate(format: "label == %@", "question 1")
        ).firstMatch
        XCTAssertFalse(oldest.exists, "the earlier pages start out unfetched")

        for _ in 0..<8 where !oldest.exists {
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
            "once the first turn is loaded there is no earlier page to offer"
        )
    }

    func testAConversationWhoseHistoryArrivesLateStillOpensAtTheNewestTurn() throws {
        // The device symptom: the first page lands after the screen is up, and
        // it is taller than the screen. That must not be read as the reader
        // having scrolled away from the newest end.
        let app = launchMockedApp(slowHistory: true)
        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        app.tabBars.buttons["Projects"].tap()
        let project = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-row-"))
            .firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20))
        project.tap()
        let session = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-session-"))
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 20))
        session.tap()

        let newest = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "answer 20")
        ).firstMatch
        XCTAssertTrue(
            newest.waitForExistence(timeout: 20),
            "a transcript must open on its newest turn even when its history is slow"
        )
    }
}
