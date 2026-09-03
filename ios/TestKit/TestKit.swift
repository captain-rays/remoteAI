import Foundation

/// Minimal, dependency-free test harness.
///
/// The development Mac only has Command Line Tools, so `XCTest` cannot be
/// linked from SwiftPM. These primitives let the same suite bodies run today
/// via `swift run remoteai-tests` and, once full Xcode is installed, from an
/// `XCTest` bundle through `RemoteAITests/XCTestBridge.swift`.

public struct ExpectationFailure: Error, CustomStringConvertible {
    public let message: String
    public let file: StaticString
    public let line: UInt

    public init(message: String, file: StaticString, line: UInt) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String {
        "\(file):\(line): \(message)"
    }
}

public func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ note: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard actual != expected else { return }
    let suffix = note.isEmpty ? "" : " — \(note)"
    throw ExpectationFailure(
        message: "expected \(expected), got \(actual)\(suffix)",
        file: file,
        line: line
    )
}

public func expectTrue(
    _ value: Bool,
    _ note: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard !value else { return }
    let suffix = note.isEmpty ? "" : " — \(note)"
    throw ExpectationFailure(message: "expected true\(suffix)", file: file, line: line)
}

public func expectFalse(
    _ value: Bool,
    _ note: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try expectTrue(!value, note, file: file, line: line)
}

public func expectNil(
    _ value: Any?,
    _ note: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard let value else { return }
    let suffix = note.isEmpty ? "" : " — \(note)"
    throw ExpectationFailure(message: "expected nil, got \(value)\(suffix)", file: file, line: line)
}

@discardableResult
public func expectNotNil<T>(
    _ value: T?,
    _ note: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        let suffix = note.isEmpty ? "" : " — \(note)"
        throw ExpectationFailure(message: "expected non-nil\(suffix)", file: file, line: line)
    }
    return value
}

/// Asserts that `body` throws, and returns the thrown error for inspection.
@discardableResult
public func expectThrows(
    _ note: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async throws -> Error {
    do {
        try await body()
    } catch {
        return error
    }
    let suffix = note.isEmpty ? "" : " — \(note)"
    throw ExpectationFailure(message: "expected a thrown error\(suffix)", file: file, line: line)
}

public struct TestCase {
    public let name: String
    public let body: () async throws -> Void

    public init(_ name: String, _ body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

public struct TestSuite {
    public let name: String
    public let cases: [TestCase]

    public init(name: String, cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}

public struct TestResult {
    public let suite: String
    public let test: String
    public let failure: String?

    public init(suite: String, test: String, failure: String?) {
        self.suite = suite
        self.test = test
        self.failure = failure
    }

    public var passed: Bool { failure == nil }
}

public enum TestRunner {
    /// Runs every case and returns one result per case. Never throws.
    public static func run(_ suites: [TestSuite]) async -> [TestResult] {
        var results: [TestResult] = []
        for suite in suites {
            for testCase in suite.cases {
                do {
                    try await testCase.body()
                    results.append(TestResult(suite: suite.name, test: testCase.name, failure: nil))
                } catch {
                    results.append(
                        TestResult(suite: suite.name, test: testCase.name, failure: "\(error)")
                    )
                }
            }
        }
        return results
    }

    /// Runs the suites, prints a TAP-like report, and returns the process exit code.
    public static func main(_ suites: [TestSuite]) async -> Int32 {
        let results = await run(suites)
        var currentSuite = ""
        for result in results {
            if result.suite != currentSuite {
                currentSuite = result.suite
                print("")
                print("# \(currentSuite)")
            }
            if let failure = result.failure {
                print("not ok - \(result.test)")
                print("  \(failure)")
            } else {
                print("ok - \(result.test)")
            }
        }
        let failed = results.filter { !$0.passed }
        print("")
        print("\(results.count) tests, \(failed.count) failures")
        return failed.isEmpty ? 0 : 1
    }
}
