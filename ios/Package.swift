// swift-tools-version: 5.9
import PackageDescription

// RemoteAI iOS client, lane B.
//
// The app's whole implementation lives in the `RemoteAIKit` library so that it
// can be compiled and exercised without a full Xcode installation. The Xcode
// application target (see `project.yml`) contributes only `App/RemoteAIApp.swift`,
// which is excluded here because `@main` cannot live in a library.
let package = Package(
    name: "RemoteAI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RemoteAIKit", targets: ["RemoteAIKit"]),
        // Exposed so the Xcode XCTest bundle can run the very same suites.
        .library(name: "RemoteAITestKit", targets: ["RemoteAITestKit"]),
        .library(name: "RemoteAISuites", targets: ["RemoteAISuites"]),
        .executable(name: "remoteai-tests", targets: ["RemoteAITestRunner"]),
    ],
    targets: [
        .target(
            name: "RemoteAIKit",
            path: "RemoteAI",
            exclude: ["App/RemoteAIApp.swift"]
        ),
        .target(
            name: "RemoteAITestKit",
            path: "TestKit"
        ),
        .target(
            name: "RemoteAISuites",
            dependencies: ["RemoteAIKit", "RemoteAITestKit"],
            path: "RemoteAITests"
        ),
        .executableTarget(
            name: "RemoteAITestRunner",
            dependencies: ["RemoteAISuites", "RemoteAITestKit"],
            path: "RemoteAITestRunner"
        ),
    ]
)
