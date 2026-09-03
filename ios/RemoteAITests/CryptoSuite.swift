import CryptoKit
import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum CryptoSuite {

    static func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func hex(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { index in
            let start = value.index(value.startIndex, offsetBy: index)
            let end = value.index(start, offsetBy: 2)
            return UInt8(value[start..<end], radix: 16)!
        })
    }

    static func pairingJSON(expiresAt: String, secret: String = "c2VjcmV0LXZhbHVl") -> String {
        let macKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        return """
        {
          "origin": "https://remoteai.example.com",
          "macId": "mac-1",
          "macPublicKey": "\(macKey)",
          "pairingSecret": "\(secret)",
          "expiresAt": "\(expiresAt)"
        }
        """
    }

    public static let suite = TestSuite(
        name: "CryptoSuite",
        cases: [
            TestCase("both peers derive identical directional keys") {
                let phone = P256.KeyAgreement.PrivateKey()
                let mac = P256.KeyAgreement.PrivateKey()
                let salt = Data("remoteai-v1".utf8)

                let phoneSide = try SessionKeys.derive(
                    privateKey: phone, peerPublicKey: mac.publicKey, salt: salt
                )
                let macSide = try SessionKeys.derive(
                    privateKey: mac, peerPublicKey: phone.publicKey, salt: salt
                )

                try expectEqual(keyBytes(phoneSide.phoneToMac), keyBytes(macSide.phoneToMac))
                try expectEqual(keyBytes(phoneSide.macToPhone), keyBytes(macSide.macToPhone))
            },

            TestCase("the two directions use different keys") {
                let phone = P256.KeyAgreement.PrivateKey()
                let mac = P256.KeyAgreement.PrivateKey()
                let keys = try SessionKeys.derive(
                    privateKey: phone, peerPublicKey: mac.publicKey, salt: Data("s".utf8)
                )
                try expectFalse(
                    keyBytes(keys.phoneToMac) == keyBytes(keys.macToPhone),
                    "a single key in both directions would allow reflection"
                )
            },

            TestCase("directional keys match the Rust protocol vector") {
                let phone = try P256.KeyAgreement.PrivateKey(
                    rawRepresentation: hex(
                        "0000000000000000000000000000000000000000000000000000000000000001"
                    )
                )
                let mac = try P256.KeyAgreement.PublicKey(
                    x963Representation: hex(
                        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
                    )
                )
                let keys = try SessionKeys.derive(
                    privateKey: phone,
                    peerPublicKey: mac,
                    macId: "mac-1",
                    deviceId: "phone-1"
                )
                try expectEqual(
                    keyBytes(keys.phoneToMac),
                    hex("fe99dca6260ab356477e502fe5df8a5ae7bf31b0be49129c75a90fc055b6015c")
                )
                try expectEqual(
                    keyBytes(keys.macToPhone),
                    hex("47bb3375b2095cf6aef154456c6e1da6d75e16369061127682e742a9a31ccc05")
                )
            },

            TestCase("nonces are a four-byte direction prefix plus a big-endian counter") {
                let nonce = try CryptoBox.nonceBytes(direction: .phoneToMac, counter: 1)
                try expectEqual(nonce.count, 12)
                try expectEqual(Array(nonce.prefix(4)), Array(Data("IOS>".utf8)))
                try expectEqual(Array(nonce.suffix(8)), [0, 0, 0, 0, 0, 0, 0, 1])

                let other = try CryptoBox.nonceBytes(direction: .macToPhone, counter: 1)
                try expectEqual(Array(other.prefix(4)), Array(Data("MAC>".utf8)))
                try expectFalse(nonce == other, "direction must be part of the nonce")
            },

            TestCase("routing metadata bytes match the Rust AAD serialization") {
                let routing = RoutingMetadata(deviceId: "phone-1", conversationId: "conv-1")
                let aad = try routing.canonicalData()
                try expectEqual(
                    String(decoding: aad, as: UTF8.self),
                    "{\"deviceId\":\"phone-1\",\"conversationId\":\"conv-1\"}"
                )
                let frame = EncryptedFrame(
                    counter: 7, routing: routing, ciphertext: "AQID"
                )
                let wire = try JSONEncoder().encode(frame)
                let object = try expectNotNil(
                    try JSONSerialization.jsonObject(with: wire) as? [String: Any]
                )
                try expectEqual(object["counter"] as? Int, 7)
                try expectEqual(object["ciphertext"] as? String, "AQID")
            },

            TestCase("remote client endpoint rejects credential-bearing origins") {
                let endpoint = try await expectThrows {
                    _ = try RemoteAgentClient.endpoint(
                        origin: URL(string: "https://user:password@example.com")!,
                        path: "v1/diagnostics"
                    )
                }
                try expectEqual(endpoint as? AgentClientError, .invalidRequest("invalid agent origin"))
            },

            TestCase("streaming keeps deltas and closes on terminal events") {
                let delta = EventEnvelope(
                    sequence: 1,
                    conversationId: "conv-1",
                    rawType: "conversation.delta",
                    event: .unsupported(rawType: "conversation.delta")
                )
                let completed = EventEnvelope(
                    sequence: 2,
                    conversationId: "conv-1",
                    rawType: "turn.completed",
                    event: .unsupported(rawType: "turn.completed")
                )
                try expectTrue(RemoteAgentClient.shouldKeepSocket(after: delta))
                try expectFalse(RemoteAgentClient.shouldKeepSocket(after: completed))
            },

            TestCase("response counters reset for each websocket connection") {
                try expectTrue(
                    RemoteAgentClient.responseCountersAreScopedToConnections(
                        [[1, 2], [1]]
                    )
                )
                try expectFalse(
                    RemoteAgentClient.responseCountersAreScopedToConnections(
                        [[1, 1], [1]]
                    )
                )
            },

            TestCase("websocket failures expose only a safe lifecycle stage") {
                try expectEqual(
                    RemoteAgentClient.socketFailureMessage(stage: "send"),
                    "The message could not reach the Mac."
                )
                try expectEqual(
                    RemoteAgentClient.socketFailureMessage(stage: "receive"),
                    "The Mac WebSocket closed before responding."
                )
                try expectEqual(
                    RemoteAgentClient.socketFailureMessage(stage: "timeout"),
                    "The Mac did not finish the turn in time."
                )
            },

            TestCase("remote wire maps start DTO and authenticates frame routing") {
                let response = RemoteAgentClient.StartResponse(
                    conversationId: "conv-1", provider: .codex
                )
                let summary = RemoteAgentClient.conversationSummary(
                    from: response,
                    kind: .daily,
                    cwd: nil,
                    now: Date(timeIntervalSince1970: 0)
                )
                try expectEqual(summary.id, "conv-1")
                try expectEqual(summary.provider, .codex)
                let routing = RoutingMetadata(deviceId: "phone-1", conversationId: "conv-1")
                let plaintext = Data("{\"kind\":\"request\",\"type\":\"conversation.send\"}".utf8)
                let key = SymmetricKey(size: .bits256)
                let frame = try RemoteAgentClient.makeEncryptedFrame(
                    plaintext: plaintext, counter: 3, routing: routing, key: key
                )
                let ciphertext = try expectNotNil(Data(base64Encoded: frame.ciphertext))
                let opened = try CryptoBox(key: key, direction: .phoneToMac).open(
                    ciphertext, counter: frame.counter, aad: frame.routing.canonicalData()
                )
                try expectEqual(opened, plaintext)
            },

            TestCase("a sealed frame round-trips between the two peers") {
                let phone = P256.KeyAgreement.PrivateKey()
                let mac = P256.KeyAgreement.PrivateKey()
                let salt = Data("remoteai-v1".utf8)
                let phoneKeys = try SessionKeys.derive(
                    privateKey: phone, peerPublicKey: mac.publicKey, salt: salt
                )
                let macKeys = try SessionKeys.derive(
                    privateKey: mac, peerPublicKey: phone.publicKey, salt: salt
                )

                let sender = CryptoBox(key: phoneKeys.phoneToMac, direction: .phoneToMac)
                let receiver = CryptoBox(key: macKeys.phoneToMac, direction: .phoneToMac)
                let aad = Data("conversation.send|codex-daily-1".utf8)

                let sealed = try sender.seal(Data("hello".utf8), counter: 7, aad: aad)
                let opened = try receiver.open(sealed, counter: 7, aad: aad)
                try expectEqual(String(decoding: opened, as: UTF8.self), "hello")
            },

            TestCase("routing metadata is authenticated, so tampering fails the open") {
                let key = SymmetricKey(size: .bits256)
                let box = CryptoBox(key: key, direction: .phoneToMac)
                let sealed = try box.seal(
                    Data("hello".utf8), counter: 1, aad: Data("files.list|/Users/dev".utf8)
                )
                _ = try await expectThrows {
                    _ = try box.open(sealed, counter: 1, aad: Data("files.list|/etc".utf8))
                }
            },

            TestCase("a frame opened with the wrong counter is rejected") {
                let key = SymmetricKey(size: .bits256)
                let box = CryptoBox(key: key, direction: .phoneToMac)
                let sealed = try box.seal(Data("hello".utf8), counter: 4, aad: Data())
                _ = try await expectThrows {
                    _ = try box.open(sealed, counter: 5, aad: Data())
                }
            },

            TestCase("counters must strictly increase, so replays are refused") {
                var guardState = ReplayGuard()
                try expectTrue(guardState.accept(counter: 1))
                try expectTrue(guardState.accept(counter: 2))
                try expectFalse(guardState.accept(counter: 2), "replayed counter")
                try expectFalse(guardState.accept(counter: 1), "older counter")
                try expectTrue(guardState.accept(counter: 9))
                try expectEqual(guardState.lastCounter, 9)
            },

            TestCase("a valid pairing payload decodes from the QR string") {
                let payload = try PairingPayload.decode(pairingJSON(expiresAt: "2026-09-03T10:05:00Z"))
                try expectEqual(payload.origin, "https://remoteai.example.com")
                try expectEqual(payload.macId, "mac-1")
                try expectFalse(payload.pairingSecret.isEmpty)
                try payload.validate(now: ISO8601DateFormatter().date(from: "2026-09-03T10:00:00Z")!)
            },

            TestCase("an expired pairing payload is rejected") {
                let payload = try PairingPayload.decode(pairingJSON(expiresAt: "2026-09-03T10:05:00Z"))
                let error = try await expectThrows {
                    try payload.validate(
                        now: ISO8601DateFormatter().date(from: "2026-09-03T10:05:01Z")!
                    )
                }
                try expectEqual(error as? CryptoError, .pairingExpired)
            },

            TestCase("a pairing payload over a plaintext origin is rejected") {
                let json = pairingJSON(expiresAt: "2026-09-03T10:05:00Z")
                    .replacingOccurrences(of: "https://", with: "http://")
                let payload = try PairingPayload.decode(json)
                let error = try await expectThrows {
                    try payload.validate(
                        now: ISO8601DateFormatter().date(from: "2026-09-03T10:00:00Z")!
                    )
                }
                try expectEqual(error as? CryptoError, .insecureOrigin)
            },

            TestCase("a loopback http origin is accepted for local development") {
                // The Mac agent binds 127.0.0.1 and is published over the
                // tunnel as https. Talking to the loopback address directly
                // never puts a frame on a network, so http is safe there —
                // and it is the only way to pair against a local agent.
                let now = ISO8601DateFormatter().date(from: "2026-09-03T10:00:00Z")!
                for origin in [
                    "http://127.0.0.1:8787", "http://localhost:8787", "http://[::1]:8787",
                ] {
                    let json = pairingJSON(expiresAt: "2026-09-03T10:05:00Z")
                        .replacingOccurrences(of: "https://remoteai.example.com", with: origin)
                    let payload = try PairingPayload.decode(json)
                    try payload.validate(now: now)
                }
            },

            TestCase("a non-loopback http origin is still rejected") {
                let now = ISO8601DateFormatter().date(from: "2026-09-03T10:00:00Z")!
                for origin in [
                    "http://10.0.0.5:8787",
                    "http://remoteai.example.com",
                    // Must not be fooled by a hostname that merely starts with
                    // a loopback-looking prefix.
                    "http://127.0.0.1.evil.example.com",
                    "http://localhost.evil.example.com",
                ] {
                    let json = pairingJSON(expiresAt: "2026-09-03T10:05:00Z")
                        .replacingOccurrences(of: "https://remoteai.example.com", with: origin)
                    let payload = try PairingPayload.decode(json)
                    let error = try await expectThrows("\(origin) must be refused") {
                        try payload.validate(now: now)
                    }
                    try expectEqual(error as? CryptoError, .insecureOrigin, origin)
                }
            },

            TestCase("malformed QR text is rejected without crashing") {
                let error = try await expectThrows {
                    _ = try PairingPayload.decode("not json at all")
                }
                try expectEqual(error as? CryptoError, .malformedPairingPayload)
            },

            TestCase("a one-time pairing secret cannot be used twice") {
                let registry = UsedSecretRegistry()
                let secret = Data("secret-value".utf8)
                try expectTrue(registry.claim(secret))
                try expectFalse(registry.claim(secret), "single-use secret")
            },

            TestCase("device material round-trips through the secret store and is erased on revoke") {
                let store = InMemorySecretStore()
                let identity = DeviceIdentity(
                    macId: "mac-1",
                    origin: "https://remoteai.example.com",
                    privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation,
                    macPublicKey: P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                )
                try store.save(identity)
                let loaded = try expectNotNil(try store.load())
                try expectEqual(loaded.macId, "mac-1")
                try expectEqual(loaded.privateKey, identity.privateKey)

                try store.deleteAll()
                try expectNil(try store.load())
            },

            TestCase("the secret store never holds vendor credentials") {
                let mirror = Mirror(reflecting: DeviceIdentity.self)
                _ = mirror
                let fields = DeviceIdentity.storedFieldNames
                try expectEqual(
                    fields, ["macId", "origin", "privateKey", "macPublicKey"],
                    "no field may carry a Codex or Claude token"
                )
            },
        ]
    )
}
