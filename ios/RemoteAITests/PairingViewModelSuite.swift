import CryptoKit
import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum PairingViewModelSuite {

    final class Flag: @unchecked Sendable { var value = false }
    final class HTTPFailureService: PairingService, @unchecked Sendable {
        func completePairing(payload: PairingPayload, phonePublicKey: Data) async throws -> Bool {
            throw RemotePairingError.httpStatus(401)
        }
    }

    static let now = ISO8601DateFormatter().date(from: "2026-09-03T10:00:00Z")!

    static func qr(
        expiresAt: String = "2026-09-03T10:05:00Z",
        origin: String = "https://remoteai.example.com",
        secret: String = "c2VjcmV0LXZhbHVl"
    ) -> String {
        let macKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        return """
        {
          "origin": "\(origin)",
          "macId": "mac-1",
          "macPublicKey": "\(macKey)",
          "pairingSecret": "\(secret)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    @MainActor
    static func makeViewModel(
        store: SecretStore = InMemorySecretStore(),
        registry: UsedSecretRegistry = UsedSecretRegistry(),
        service: PairingService = MockPairingService()
    ) -> PairingViewModel {
        PairingViewModel(store: store, registry: registry, service: service, now: { now })
    }

    public static let suite = TestSuite(
        name: "PairingViewModelSuite",
        cases: [
            TestCase("a valid QR code pairs and stores the device identity") {
                let store = InMemorySecretStore()
                let model = await makeViewModel(store: store)
                await model.pair(scannedText: qr())

                try expectEqual(await model.state, .paired)
                let identity = try expectNotNil(try store.load())
                try expectEqual(identity.macId, "mac-1")
                try expectEqual(identity.origin, "https://remoteai.example.com")
                try expectFalse(identity.privateKey.isEmpty)
            },

            TestCase("successful pairing invokes the connection hook") {
                let model = await makeViewModel()
                let didPair = Flag()
                await MainActor.run { model.onPaired = { didPair.value = true } }
                await model.pair(scannedText: qr())
                try expectTrue(didPair.value)
            },

            TestCase("an expired QR code is refused and stores nothing") {
                let store = InMemorySecretStore()
                let model = await makeViewModel(store: store)
                await model.pair(scannedText: qr(expiresAt: "2026-09-03T09:59:59Z"))

                try expectEqual(await model.state, .failed("This pairing code has expired."))
                try expectNil(try store.load())
            },

            TestCase("Rust RFC3339 fractional expiresAt decodes") {
                let payload = try PairingPayload.decode(
                    qr(expiresAt: "2026-09-03T10:05:41.580758Z")
                )
                try payload.validate(now: now)
            },

            TestCase("a plaintext origin is refused") {
                let model = await makeViewModel()
                await model.pair(scannedText: qr(origin: "http://remoteai.example.com"))
                try expectEqual(
                    await model.state, .failed("This Mac address is not encrypted.")
                )
            },

            TestCase("unreadable QR text is refused without crashing") {
                let model = await makeViewModel()
                await model.pair(scannedText: "definitely not a pairing code")
                try expectEqual(
                    await model.state, .failed("This is not a RemoteAI pairing code.")
                )
            },

            TestCase("a pairing secret cannot be reused") {
                let registry = UsedSecretRegistry()
                let first = await makeViewModel(registry: registry)
                await first.pair(scannedText: qr())
                try expectEqual(await first.state, .paired)

                let second = await makeViewModel(registry: registry)
                await second.pair(scannedText: qr())
                try expectEqual(
                    await second.state, .failed("This pairing code has already been used.")
                )
            },

            TestCase("a rejected pairing on the Mac leaves nothing stored") {
                let store = InMemorySecretStore()
                let model = await makeViewModel(
                    store: store, service: MockPairingService(shouldSucceed: false)
                )
                await model.pair(scannedText: qr())
                try expectEqual(await model.state, .failed("The Mac refused this pairing code."))
                try expectNil(try store.load())
            },

            TestCase("remote HTTP failure exposes only a safe status diagnostic") {
                let model = await makeViewModel(service: HTTPFailureService())
                await model.pair(scannedText: qr())
                try expectEqual(
                    await model.state, .failed("Pairing request failed (HTTP 401).")
                )
            },

            TestCase("revoking erases the device key") {
                let store = InMemorySecretStore()
                let model = await makeViewModel(store: store)
                await model.pair(scannedText: qr())
                try expectNotNil(try store.load())

                await model.revoke()
                try expectNil(try store.load())
                try expectEqual(await model.state, .idle)
            },

            TestCase("remote pairing request carries the secret and device identity") {
                let payload = PairingPayload(
                    origin: "https://tunnel.example",
                    macId: "mac-1",
                    macPublicKey: Data([4, 1]),
                    pairingSecret: Data("secret-value".utf8),
                    expiresAt: now
                )
                let request = try RemotePairingService.makePairRequest(
                    payload: payload,
                    deviceId: "phone-1",
                    deviceLabel: "Test iPhone",
                    phonePublicKey: Data([4, 2])
                )
                try expectEqual(request.url?.absoluteString, "https://tunnel.example/v1/pair")
                try expectEqual(request.httpMethod, "POST")
                let body = try expectNotNil(request.httpBody)
                let json = try expectNotNil(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                try expectEqual(json["pairingSecret"] as? String, "secret-value")
                try expectEqual(json["deviceId"] as? String, "phone-1")
                try expectEqual(json["devicePublicKey"] as? [UInt8], [4, 2])
            },

            TestCase("default device id is stable from the phone public key") {
                let key = Data([4, 1, 2, 3])
                try expectEqual(
                    RemotePairingService.deterministicDeviceId(publicKey: key),
                    RemotePairingService.deterministicDeviceId(publicKey: key)
                )
                try expectFalse(
                    RemotePairingService.deterministicDeviceId(publicKey: key).isEmpty
                )
            },

            TestCase("pairing payload accepts the Agent's JSON byte representation") {
                let text = """
                {"origin":"https://agent.example","macId":"mac-1","macPublicKey":[4,1],"pairingSecret":"one-time-secret","expiresAt":"2026-09-03T10:05:00Z"}
                """
                let payload = try PairingPayload.decode(text)
                try expectEqual(payload.macPublicKey, Data([4, 1]))
                try expectEqual(payload.pairingSecret, Data("one-time-secret".utf8))
            },
        ]
    )
}

public enum SettingsViewModelSuite {

    @MainActor
    static func makeViewModel(
        client: MockAgentClient = MockAgentClient(),
        cache: CatalogCache = InMemoryCatalogCache()
    ) -> SettingsViewModel {
        SettingsViewModel(client: client, cache: cache, store: InMemorySecretStore())
    }

    public static let suite = TestSuite(
        name: "SettingsViewModelSuite",
        cases: [
            TestCase("diagnostics report the agent, tunnel and both providers") {
                let model = await makeViewModel()
                await model.reload()
                let diagnostics = try expectNotNil(await model.diagnostics)
                try expectEqual(diagnostics.providers.count, 2)
                try expectTrue(diagnostics.tunnelHealthy)
                try expectEqual(diagnostics.endpoint, "https://remoteai.example.com")
            },

            TestCase("audit rows are shown newest first") {
                let model = await makeViewModel()
                await model.reload()
                let rows = await model.auditEntries
                try expectTrue(rows.count >= 2)
                try expectEqual(rows, rows.sorted { $0.timestamp > $1.timestamp })
            },

            TestCase("no audit row can carry a credential") {
                let model = await makeViewModel()
                await model.reload()
                for row in await model.auditEntries {
                    let text = "\(row)".lowercased()
                    for banned in ["token", "secret", "password", "cookie", "api_key"] {
                        try expectFalse(text.contains(banned), "audit row leaked \(banned)")
                    }
                }
            },

            TestCase("clearing the cache empties every provider's snapshot") {
                let cache = InMemoryCatalogCache()
                cache.store(
                    CatalogSnapshot(provider: .codex, dailyConversations: [], projects: [])
                )
                let model = await makeViewModel(cache: cache)
                await model.clearCache()
                try expectNil(cache.snapshot(for: .codex))
            },

            TestCase("revoking this phone is destructive and needs confirmation") {
                let model = await makeViewModel()
                await model.revokeDevice(confirmed: false)
                try expectFalse(await model.isRevoked)

                await model.revokeDevice(confirmed: true)
                try expectTrue(await model.isRevoked)
            },

            TestCase("opening settings issues no transfer request") {
                let client = MockAgentClient()
                let model = await makeViewModel(client: client)
                await model.reload()
                try expectEqual(await client.transferRequestCount, 0)
            },
            TestCase("a camera the phone will not allow explains itself") {
                // A scanner that fails silently is indistinguishable from one
                // pointed at a code it cannot read.
                for permission in [CameraPermission.denied, CameraPermission.restricted] {
                    let availability = CameraAvailability.of(permission, hasCamera: true)
                    let message = try expectNotNil(availability.message)
                    try expectFalse(message.isEmpty)
                    try expectFalse(
                        availability.showsViewfinder,
                        "a viewfinder that can never show a frame is a black rectangle"
                    )
                }
                try expectEqual(
                    CameraAvailability.of(CameraPermission.denied, hasCamera: true).message?
                        .contains("Settings"),
                    true,
                    "a denied camera is fixed in Settings, so say so"
                )
            },

            TestCase("a phone with no camera falls back to pasting") {
                let availability = CameraAvailability.of(CameraPermission.granted, hasCamera: false)
                try expectEqual(availability, .unavailable)
                try expectEqual(
                    availability.message?.contains("Paste the pairing code"), true
                )
            },

            TestCase("a granted camera shows the viewfinder and says nothing") {
                let availability = CameraAvailability.of(CameraPermission.granted, hasCamera: true)
                try expectEqual(availability, .ready)
                try expectNil(availability.message)
                try expectTrue(availability.showsViewfinder)
            },

            TestCase("an unasked camera is not an error") {
                // The system prompt has not been shown yet; that is not a
                // failure to report, it is a question to ask.
                let availability = CameraAvailability.of(CameraPermission.undetermined, hasCamera: true)
                try expectEqual(availability, .needsPermission)
                try expectNil(availability.message)
            },

            TestCase("a pairing request that never arrives names the address") {
                let message = PairingViewModel.unreachableMessage(
                    origin: "https://example-tunnel.trycloudflare.com",
                    error: URLError(.cannotFindHost)
                )
                try expectTrue(
                    message.contains("example-tunnel.trycloudflare.com"),
                    "the address that failed is the first thing to check: \(message)"
                )
                try expectTrue(
                    message.contains("VPN"),
                    "a host that will not resolve is usually the phone's network: \(message)"
                )
                try expectFalse(
                    message.contains("could not be completed"),
                    "\"could not be completed\" says nothing actionable"
                )
            },

            TestCase("a timeout and an offline phone read differently") {
                let timedOut = PairingViewModel.unreachableMessage(
                    origin: "https://mac.example.com", error: URLError(.timedOut)
                )
                let offline = PairingViewModel.unreachableMessage(
                    origin: "https://mac.example.com", error: URLError(.notConnectedToInternet)
                )
                try expectTrue(timedOut.contains("did not answer"))
                try expectTrue(offline.contains("offline"))
                try expectFalse(timedOut == offline)
            },

            TestCase("pairing is addressed to the Mac named in the scanned code") {
                // The QR carries where the Mac is; that is the whole point of
                // putting an origin in it. Addressing a preconfigured origin
                // instead sends the request to whatever the app was built
                // with — on a real phone, its own loopback.
                let payload = PairingPayload(
                    origin: "https://tunnel.example.com",
                    macId: "mac-1",
                    macPublicKey: Data([4, 2]),
                    pairingSecret: Data("secret-1".utf8),
                    expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
                )
                let request = try RemotePairingService.makePairRequest(
                    payload: payload,
                    deviceId: "device-1",
                    deviceLabel: "iPhone",
                    phonePublicKey: Data([4, 9])
                )
                try expectEqual(request.url?.host, "tunnel.example.com")
                try expectEqual(request.url?.scheme, "https")
                try expectEqual(request.url?.path, "/v1/pair")
                try expectFalse(
                    request.url?.absoluteString.contains("127.0.0.1") ?? true,
                    "the phone's own loopback is never the Mac"
                )
            },

            TestCase("a scanned code with an unusable origin is refused") {
                let payload = PairingPayload(
                    origin: "not a url at all",
                    macId: "mac-1",
                    macPublicKey: Data([4, 2]),
                    pairingSecret: Data("secret-1".utf8),
                    expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
                )
                try await expectThrows {
                    _ = try RemotePairingService.makePairRequest(
                        payload: payload,
                        deviceId: "device-1",
                        deviceLabel: "iPhone",
                        phonePublicKey: Data([4, 9])
                    )
                }
            },

        ]
    )
}
