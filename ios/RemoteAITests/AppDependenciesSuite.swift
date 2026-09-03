import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum AppDependenciesSuite {

    final class RecordingPairingService: PairingService, @unchecked Sendable {
        private(set) var callCount = 0

        func completePairing(payload: PairingPayload, phonePublicKey: Data) async throws -> Bool {
            callCount += 1
            return true
        }
    }

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

            TestCase("agent public origin comes from an explicit launch argument") {
                let dependencies = await MainActor.run {
                    AppDependencies.live(
                        arguments: ["RemoteAI", "-AgentPublicOrigin", "https://tunnel.example"]
                    )
                }
                try expectEqual(await dependencies.publicOrigin, "https://tunnel.example")
                try expectFalse(
                    await dependencies.appModel.isOnline,
                    "a real endpoint stays disconnected until pairing"
                )
            },

            TestCase("explicit pairing bootstrap uses an ephemeral simulator store") {
                let dependencies = await MainActor.run {
                    AppDependencies.live(
                        arguments: ["RemoteAI", "-RemoteAIPairingPayload", "{}"]
                    )
                }
                try expectTrue(await dependencies.usesEphemeralPairingStore)
                let production = await MainActor.run { AppDependencies.live(arguments: ["RemoteAI"]) }
                try expectFalse(await production.usesEphemeralPairingStore)
            },

            TestCase("pairing file launch argument is opt-in and parsed once") {
                let url = URL(fileURLWithPath: "/tmp/remoteai-pairing.json")
                try expectEqual(
                    AppDependencies.pairingFileURL(
                        arguments: ["RemoteAI", "-RemoteAIPairingFile", url.path]
                    ),
                    url
                )
                try expectNil(AppDependencies.pairingFileURL(arguments: ["RemoteAI"]))
                try expectNil(
                    AppDependencies.pairingFileURL(
                        arguments: ["RemoteAI", "-RemoteAIPairingFile", "-UseMockAgent"]
                    )
                )
            },

            TestCase("inline pairing payload takes priority and is bounded") {
                let payload = "{\"pairingSecret\":\"one-time\"}"
                try expectEqual(
                    AppDependencies.pairingPayload(
                        arguments: ["RemoteAI", "-RemoteAIPairingPayload", payload]
                    ),
                    payload
                )
                try expectNil(
                    AppDependencies.pairingPayload(
                        arguments: ["RemoteAI", "-RemoteAIPairingPayload", "-UseMockAgent"]
                    )
                )
            },

            TestCase("explicit pairing file triggers one handshake and online hook") {
                let service = RecordingPairingService()
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent("remoteai-pairing-\(UUID().uuidString).json")
                try Data(PairingViewModelSuite.qr(secret: "file-bootstrap-secret").utf8)
                    .write(to: path, options: .completeFileProtection)
                defer { try? FileManager.default.removeItem(at: path) }
                let dependencies = await MainActor.run {
                    AppDependencies(
                        client: MockAgentClient(),
                        preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache(),
                        store: InMemorySecretStore(),
                        pairingService: service
                    )
                }
                await dependencies.bootstrapPairingIfRequested(
                    arguments: ["RemoteAI", "-RemoteAIPairingFile", path.path]
                )
                try expectEqual(service.callCount, 1)
                try expectTrue(await dependencies.appModel.isOnline)
                try expectEqual(await dependencies.connectionState, .online)
                try expectEqual(await dependencies.launchPairingStatus, .paired)
                await dependencies.bootstrapPairingIfRequested(
                    arguments: ["RemoteAI", "-RemoteAIPairingFile", path.path]
                )
                try expectEqual(service.callCount, 1)
            },

            TestCase("inline pairing payload triggers bootstrap before file") {
                let service = RecordingPairingService()
                let dependencies = await MainActor.run {
                    AppDependencies(
                        client: MockAgentClient(),
                        preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache(),
                        store: InMemorySecretStore(),
                        pairingService: service
                    )
                }
                await dependencies.bootstrapPairingIfRequested(
                    arguments: [
                        "RemoteAI", "-RemoteAIPairingPayload",
                        PairingViewModelSuite.qr(secret: "inline-bootstrap-secret"),
                        "-RemoteAIPairingFile", "/definitely/not/read"
                    ]
                )
                try expectEqual(service.callCount, 1)
                try expectTrue(await dependencies.appModel.isOnline)
                try expectEqual(await dependencies.launchPairingStatus, .paired)
            },

            TestCase("duplicate dependency instances share one pairing attempt") {
                let firstService = RecordingPairingService()
                let secondService = RecordingPairingService()
                let payload = PairingViewModelSuite.qr(secret: "shared-bootstrap-secret")
                let first = await MainActor.run {
                    AppDependencies(
                        client: MockAgentClient(), preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache(), store: InMemorySecretStore(),
                        pairingService: firstService
                    )
                }
                let second = await MainActor.run {
                    AppDependencies(
                        client: MockAgentClient(), preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache(), store: InMemorySecretStore(),
                        pairingService: secondService
                    )
                }
                await first.bootstrapPairingIfRequested(
                    arguments: ["RemoteAI", "-RemoteAIPairingPayload", payload]
                )
                await second.bootstrapPairingIfRequested(
                    arguments: ["RemoteAI", "-RemoteAIPairingPayload", payload]
                )
                try expectEqual(firstService.callCount, 1)
                try expectEqual(secondService.callCount, 0)
                try expectEqual(await second.connectionState, .online)
            },

            TestCase("mock live dependencies start with the in-process agent online") {
                let dependencies = await MainActor.run {
                    AppDependencies.live(arguments: ["RemoteAI", "-UseMockAgent"])
                }
                try expectTrue(await dependencies.appModel.isOnline)
                try expectTrue(await dependencies.files.isOnline)
                try expectTrue(await dependencies.transfers.isOnline)
            },

            TestCase("mock document picker can inject an explicit fixture") {
                let dependencies = await MainActor.run {
                    AppDependencies.live(
                        arguments: ["RemoteAI", "-UseMockAgent", "-UITestMockDocumentPicker"]
                    )
                }
                try expectEqual(await dependencies.uploadFixture?.name, "README.md")
            },
        ]
    )
}
