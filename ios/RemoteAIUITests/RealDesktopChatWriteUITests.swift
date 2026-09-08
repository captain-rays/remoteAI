import XCTest

/// Opens one of the desktop app's own chats from the phone, reads its history
/// and writes a turn into it — the path that used to fail with "no
/// conversation found" because the transcript lives inside the chat's private
/// directory.
///
/// OPT-IN: needs a live agent and spends one small provider turn. The pairing
/// secret is single-use, so run this class on its own after restarting the
/// agent.
final class RealDesktopChatWriteUITests: XCTestCase {

    /// Which chat to write into. Deliberately a throwaway one; never a chat
    /// whose contents matter.
    private let chatTitle =
        ProcessInfo.processInfo.environment["REMOTEAI_UITEST_CHAT"] ?? "Greeting"

    private var pairingFile: String? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["REMOTEAI_PAIRING_FILE"] {
            candidates.append(explicit)
        }
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            candidates.append(hostHome + "/Library/Application Support/RemoteAI/pairing.json")
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    func testWritesIntoADesktopChat() throws {
        let pairingFile = try XCTUnwrap(self.pairingFile, "no live agent configured")
        let app = XCUIApplication()
        app.launchArguments = [
            "-AgentPublicOrigin",
            ProcessInfo.processInfo.environment["REMOTEAI_AGENT_ORIGIN"]
                ?? "http://127.0.0.1:8787",
            "-RemoteAIPairingFile", pairingFile,
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pairing bootstrap: paired"].waitForExistence(timeout: 20))

        app.segmentedControls["provider-switcher"].buttons["Claude"].tap()
        app.tabBars.buttons["Chat"].tap()

        let row = app.staticTexts.containing(
            NSPredicate(format: "label == %@", chatTitle)
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 30),
            "the desktop chat '\(chatTitle)' is not in the Chats list"
        )
        row.tap()

        // Reading: the transcript lives in the chat's own sandbox.
        let anyMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "-message-"))
            .firstMatch
        XCTAssertTrue(
            anyMessage.waitForExistence(timeout: 60),
            "no history arrived for the desktop chat"
        )

        // History already contains assistant bubbles, so the reply has to be
        // counted, not merely found.
        let assistants = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        let before = assistants.count

        // Writing: resuming a desktop chat used to fail outright.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Reply with one word.")
        app.buttons["send"].tap()

        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "message-delivery-failed").firstMatch
                .waitForExistence(timeout: 10),
            "the message was reported as not sent"
        )
        let grew = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in assistants.count > before },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [grew], timeout: 180), .completed,
            "no new reply arrived: still \(before) assistant messages"
        )
    }
}
