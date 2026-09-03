import SwiftUI

/// Application entry point.
///
/// Owned by the Xcode application target only; SwiftPM excludes this file
/// because `@main` cannot appear in a library target.
@main
struct RemoteAIApp: App {
    @State private var dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
        }
    }
}
