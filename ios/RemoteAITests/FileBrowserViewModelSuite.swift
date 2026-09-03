import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum FileBrowserViewModelSuite {

    @MainActor
    static func makeViewModel(
        client: MockAgentClient = MockAgentClient(),
        online: Bool = true
    ) -> FileBrowserViewModel {
        let model = FileBrowserViewModel(
            client: client, preferences: InMemoryPreferencesStore()
        )
        model.isOnline = online
        return model
    }

    public static let suite = TestSuite(
        name: "FileBrowserViewModelSuite",
        cases: [
            TestCase("opening a directory lists its entries") {
                let model = await makeViewModel()
                await model.open("/Users/dev/work/api")
                let listing = try expectNotNil(await model.listing)
                try expectEqual(listing.path, "/Users/dev/work/api")
                try expectTrue(await model.visibleEntries.contains { $0.name == "README.md" })
            },

            TestCase("directories are listed before files") {
                let model = await makeViewModel()
                await model.open("/Users/dev/work/api")
                let kinds = await model.visibleEntries.map(\.kind)
                try expectEqual(kinds.first, .directory)
            },

            TestCase("navigating to the parent works and stops at the root") {
                let model = await makeViewModel()
                await model.open("/Users/dev/work/api")
                await model.openParent()
                try expectEqual(await model.listing?.path, "/Users/dev/work")
            },

            TestCase("a traversal path is refused before any request is made") {
                let model = await makeViewModel()
                await model.open("/Users/dev/../../etc")
                try expectNil(await model.listing)
                try expectEqual(await model.errorMessage, "This path is not allowed.")
            },

            TestCase("hidden and sensitive entries stay hidden until explicitly revealed") {
                let model = await makeViewModel()
                await model.open("/Users/dev")
                try expectFalse(await model.visibleEntries.contains { $0.hidden })

                await model.revealSensitiveEntries(confirmed: true)
                try expectTrue(await model.visibleEntries.contains { $0.hidden && $0.sensitive })
            },

            TestCase("revealing sensitive entries without confirmation does nothing") {
                let model = await makeViewModel()
                await model.open("/Users/dev")
                await model.revealSensitiveEntries(confirmed: false)
                try expectFalse(await model.showHidden)
                try expectFalse(await model.visibleEntries.contains { $0.hidden })
            },

            TestCase("search filters the current directory by name") {
                let model = await makeViewModel()
                await model.open("/Users/dev/work/api")
                await MainActor.run { model.searchText = "read" }
                let names = await model.visibleEntries.map(\.name)
                try expectEqual(names, ["README.md"], "search is case-insensitive")
            },

            TestCase("visited directories are recorded as recents, most recent first") {
                let model = await makeViewModel()
                await model.open("/Users/dev")
                await model.open("/Users/dev/work")
                await model.open("/Users/dev/work/api")
                try expectEqual(
                    await model.recentDirectories,
                    ["/Users/dev/work/api", "/Users/dev/work", "/Users/dev"]
                )
            },

            TestCase("revisiting a directory does not duplicate it in recents") {
                let model = await makeViewModel()
                await model.open("/Users/dev")
                await model.open("/Users/dev/work")
                await model.open("/Users/dev")
                try expectEqual(
                    await model.recentDirectories, ["/Users/dev", "/Users/dev/work"]
                )
            },

            TestCase("favourites can be added and removed") {
                let model = await makeViewModel()
                await model.toggleFavorite("/Users/dev/work/api")
                try expectEqual(await model.favorites, ["/Users/dev/work/api"])
                await model.toggleFavorite("/Users/dev/work/api")
                try expectEqual(await model.favorites, [])
            },

            TestCase("a text file can be previewed") {
                let model = await makeViewModel()
                await model.open("/Users/dev/work/api")
                let entry = try expectNotNil(
                    await model.visibleEntries.first { $0.name == "README.md" }
                )
                await model.loadPreview(entry)
                let preview = try expectNotNil(await model.preview)
                try expectTrue(preview.text?.contains("api") == true)
            },

            TestCase("offline browsing serves cached directories only") {
                let client = MockAgentClient()
                let model = await makeViewModel(client: client)
                await model.open("/Users/dev/work/api")

                await MainActor.run { model.isOnline = false }
                await model.open("/Users/dev/work/api")
                try expectEqual(await model.listing?.path, "/Users/dev/work/api", "cached")

                await model.open("/Users/dev/notes")
                try expectEqual(await model.listing?.path, "/Users/dev/work/api", "unchanged")
                try expectEqual(
                    await model.errorMessage,
                    "This folder has not been loaded yet, and the Mac is offline."
                )
            },

            TestCase("browsing and previewing never issues a transfer request") {
                let client = MockAgentClient()
                let model = await makeViewModel(client: client)
                await model.open("/Users/dev")
                await model.open("/Users/dev/work")
                await model.open("/Users/dev/work/api")
                await model.revealSensitiveEntries(confirmed: true)
                await model.refresh()
                let entry = try expectNotNil(
                    await model.visibleEntries.first { $0.name == "README.md" }
                )
                await model.loadPreview(entry)

                try expectEqual(
                    await client.transferRequestCount, 0,
                    "opening a folder must never move a file"
                )
            },
        ]
    )
}
