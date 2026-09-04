import CryptoKit
import XCTest

/// Exercises browsing and explicit transfers against a locally running Mac agent.
///
/// OPT-IN. The class deliberately contains one test because the pairing secret is
/// single-use. `scripts/ios-check.sh` skips it during the normal deterministic gate.
final class RealFileTransferUITests: XCTestCase {

    private var hostHome: URL? {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["REMOTEAI_HOST_HOME"] ?? environment["SIMULATOR_HOST_HOME"]
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var pairingFile: String? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["REMOTEAI_PAIRING_FILE"] {
            candidates.append(explicit)
        }
        if let hostHome {
            candidates.append(
                hostHome.appendingPathComponent(
                    "Library/Application Support/RemoteAI/pairing.json"
                ).path
            )
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    private var origin: String {
        ProcessInfo.processInfo.environment["REMOTEAI_AGENT_ORIGIN"]
            ?? "http://127.0.0.1:8787"
    }

    func testBrowseDownloadUploadAndExplicitConflictPolicies() throws {
        try XCTSkipIf(
            pairingFile == nil || hostHome == nil,
            "no live agent pairing file or simulator host home configured"
        )
        let pairingFile = try XCTUnwrap(pairingFile, "no live agent pairing file configured")
        let hostHome = try XCTUnwrap(hostHome, "no simulator host home configured")
        let fixtureDirectory = hostHome.appendingPathComponent(
            "RemoteAIFileE2E-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let downloadPayload = Data("downloaded through RemoteAI\n".utf8)
        let downloadSource = fixtureDirectory.appendingPathComponent("download-source.txt")
        try downloadPayload.write(to: downloadSource, options: .atomic)
        let expectedDownloadHash = checksum(downloadPayload)
        let uploadPayload = Data("# UI test fixture\n".utf8)
        let uploadDestination = fixtureDirectory.appendingPathComponent("README.md")
        let keepBothDestination = fixtureDirectory.appendingPathComponent("README (1).md")
        let outsideHomeProbe = hostHome.deletingLastPathComponent().appendingPathComponent(
            "RemoteAI-outside-\(UUID().uuidString)"
        )

        let app = XCUIApplication()
        app.launchArguments = [
            "-AgentPublicOrigin", origin,
            "-RemoteAIPairingFile", pairingFile,
            "-UITestMockDocumentPicker",
            "-UITestFileProbePath", outsideHomeProbe.path,
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Pairing bootstrap: paired"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Connection: online"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Files"].tap()

        let fixtureName = fixtureDirectory.lastPathComponent
        let fixtureButton = app.buttons["open-\(fixtureName)"]
        XCTAssertTrue(fixtureButton.waitForExistence(timeout: 20), "home listing never loaded")
        fixtureButton.tap()

        let downloadButton = app.buttons["download-download-source.txt"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 15))
        downloadButton.tap()
        let downloadRow = app.descendants(matching: .any)
            .matching(identifier: "transfer-local-1").firstMatch
        XCTAssertTrue(downloadRow.waitForExistence(timeout: 15))
        XCTAssertTrue(downloadRow.staticTexts["done"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            downloadRow.staticTexts["sha256 \(expectedDownloadHash.prefix(16))…"]
                .waitForExistence(timeout: 5),
            "the digest calculated from downloaded bytes differs from the Mac source"
        )

        app.buttons["upload-button"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                (try? Data(contentsOf: uploadDestination)) == uploadPayload
            },
            "the explicit upload never appeared on the Mac"
        )
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: uploadDestination.path
        )

        app.buttons["upload-button"].tap()
        let conflictRow = app.descendants(matching: .any)
            .matching(identifier: "transfer-local-3").firstMatch
        XCTAssertTrue(conflictRow.waitForExistence(timeout: 15))
        XCTAssertTrue(conflictRow.staticTexts["needs a decision"].waitForExistence(timeout: 15))
        XCTAssertEqual(try Data(contentsOf: uploadDestination), uploadPayload)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: uploadDestination.path)[.systemFileNumber]
                as? NSNumber,
            originalAttributes[.systemFileNumber] as? NSNumber,
            "the target changed before a conflict policy was chosen"
        )
        app.buttons["conflict-keep-both"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                (try? Data(contentsOf: keepBothDestination)) == uploadPayload
            },
            "keep both did not create the unique sibling"
        )
        XCTAssertEqual(try Data(contentsOf: uploadDestination), uploadPayload)

        let inodeBeforeOverwrite = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: uploadDestination.path)[.systemFileNumber]
                as? NSNumber
        )
        app.buttons["upload-button"].tap()
        XCTAssertTrue(app.buttons["conflict-overwrite"].waitForExistence(timeout: 15))
        app.buttons["conflict-overwrite"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                guard
                    let attributes = try? FileManager.default.attributesOfItem(
                        atPath: uploadDestination.path
                    ),
                    let inode = attributes[.systemFileNumber] as? NSNumber
                else { return false }
                return inode != inodeBeforeOverwrite
                    && (try? Data(contentsOf: uploadDestination)) == uploadPayload
            },
            "overwrite did not atomically replace the target"
        )

        app.buttons["uitest-file-probe"].tap()
        XCTAssertTrue(app.staticTexts["files-error"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts["files-error"].label.contains("path_outside_root"),
            "the live agent did not reject an absolute path outside HOME"
        )
    }

    private func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
