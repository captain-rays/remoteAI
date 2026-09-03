import SwiftUI

/// Application entry point.
///
/// This file is owned by the Xcode application target only; SwiftPM excludes it
/// because `@main` cannot appear in a library target.
@main
struct RemoteAIApp: App {
    var body: some Scene {
        WindowGroup {
            Text(AppMetadata.name)
        }
    }
}
