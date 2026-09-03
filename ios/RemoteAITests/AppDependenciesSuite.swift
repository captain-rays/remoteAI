import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum AppDependenciesSuite {

    @MainActor
    static func makeDependencies() -> AppDependencies {
        AppDependencies(
            client: MockAgentClient(),
            preferences: InMemoryPreferencesStore(),
            cache: InMemoryCatalogCache(),
            store: InMemorySecretStore(),
            pairingService: MockPairingService()
        )
    }

    public static let suite = TestSuite(
        name: "AppDependenciesSuite",
        cases: [
            TestCase("going offline puts every screen into read-only mode") {
                let dependencies = await makeDependencies()
                await dependencies.setConnectionState(.online)
                try expectTrue(await dependencies.appModel.isOnline)
                try expectTrue(await dependencies.files.isOnline)
                try expectTrue(await dependencies.transfers.isOnline)

                await dependencies.setConnectionState(.disconnected)
                try expectFalse(await dependencies.appModel.isOnline)
                try expectFalse(await dependencies.files.isOnline)
                try expectFalse(
                    await dependencies.transfers.isOnline,
                    "an offline phone must not be able to start a transfer"
                )
            },

            TestCase("recovering is treated as offline, not online") {
                let dependencies = await makeDependencies()
                await dependencies.setConnectionState(.recovering)
                try expectFalse(await dependencies.transfers.isOnline)
                try expectEqual(await dependencies.appModel.connectionState, .recovering)
            },

            TestCase("building the object graph issues no transfer request") {
                let client = MockAgentClient()
                let dependencies = await AppDependencies(
                    client: client,
                    preferences: InMemoryPreferencesStore(),
                    cache: InMemoryCatalogCache(),
                    store: InMemorySecretStore(),
                    pairingService: MockPairingService()
                )
                await dependencies.setConnectionState(.online)
                for _ in 0..<50 { await Task.yield() }
                try expectEqual(await client.transferRequestCount, 0)
            },

            TestCase("live dependencies are constructed on the main actor") {
                let dependencies = await MainActor.run {
                    AppDependencies.live(arguments: ["RemoteAI"])
                }
                try expectTrue(await dependencies.appModel.isOnline == false)
            },
        ]
    )
}
