import RemoteAISuites
import RemoteAITestKit
import XCTest

/// Runs every RemoteAI suite inside XCTest.
///
/// The suite bodies live in `ios/RemoteAITests` and are shared with the
/// `remoteai-tests` executable, which is how they run on a Mac that has only
/// Command Line Tools installed. Nothing is duplicated here.
final class SuiteBridgeTests: XCTestCase {

    func testAllSuitesPass() async throws {
        let results = await TestRunner.run(AllSuites.suites)
        XCTAssertFalse(results.isEmpty, "no suites were discovered")

        for result in results where !result.passed {
            XCTFail("\(result.suite) — \(result.test): \(result.failure ?? "")")
        }
    }
}
