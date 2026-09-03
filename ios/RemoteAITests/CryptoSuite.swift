import CryptoKit
import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum CryptoSuite {

    static func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
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

            TestCase("nonces are a four-byte direction prefix plus a big-endian counter") {
                let nonce = try CryptoBox.nonceBytes(direction: .phoneToMac, counter: 1)
                try expectEqual(nonce.count, 12)
                try expectEqual(Array(nonce.prefix(4)), Array(Data("P2M\u{0}".utf8)))
                try expectEqual(Array(nonce.suffix(8)), [0, 0, 0, 0, 0, 0, 0, 1])

                let other = try CryptoBox.nonceBytes(direction: .macToPhone, counter: 1)
                try expectEqual(Array(other.prefix(4)), Array(Data("M2P\u{0}".utf8)))
                try expectFalse(nonce == other, "direction must be part of the nonce")
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
