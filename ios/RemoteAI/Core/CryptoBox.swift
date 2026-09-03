import CryptoKit
import Foundation

public enum CryptoError: Error, Equatable, Sendable {
    case pairingExpired
    case insecureOrigin
    case malformedPairingPayload
    case secretAlreadyUsed
    case replayedCounter
    case sealFailed
    case openFailed
}

/// Routing fields are serialized exactly as the Rust gateway's serde struct:
/// declaration order (`deviceId`, then `conversationId`) and camelCase keys.
public struct RoutingMetadata: Codable, Sendable, Hashable {
    public let deviceId: String
    public let conversationId: String?

    public init(deviceId: String, conversationId: String?) {
        self.deviceId = deviceId
        self.conversationId = conversationId
    }

    public func canonicalData() throws -> Data {
        // Foundation's JSONEncoder may sort dictionary keys even without
        // outputFormatting; build the two-field object explicitly so its byte
        // order matches serde's declaration order on the Rust gateway.
        let encoder = JSONEncoder()
        var data = Data("{\"deviceId\":".utf8)
        data.append(try encoder.encode(deviceId))
        data.append(Data(",\"conversationId\":".utf8))
        if let conversationId {
            data.append(try encoder.encode(conversationId))
        } else {
            data.append(Data("null".utf8))
        }
        data.append(Data("}".utf8))
        return data
    }
}

public struct EncryptedFrame: Codable, Sendable, Hashable {
    public let counter: UInt64
    public let routing: RoutingMetadata
    public let ciphertext: String

    public init(counter: UInt64, routing: RoutingMetadata, ciphertext: String) {
        self.counter = counter
        self.routing = routing
        self.ciphertext = ciphertext
    }

    private enum CodingKeys: String, CodingKey { case counter, routing, ciphertext }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counter, forKey: .counter)
        try container.encode(routing, forKey: .routing)
        try container.encode(ciphertext, forKey: .ciphertext)
    }
}

/// Which side of the channel a frame travels on. The direction is part of the
/// nonce so a frame can never be reflected back at its sender.
public enum CryptoDirection: String, Sendable, Hashable, CaseIterable {
    case phoneToMac
    case macToPhone

    /// Exactly four bytes, per the frozen nonce layout.
    public var noncePrefix: Data {
        switch self {
        case .phoneToMac: return Data("IOS>".utf8)
        case .macToPhone: return Data("MAC>".utf8)
        }
    }

    /// HKDF `sharedInfo` label; distinct labels give distinct directional keys.
    var hkdfInfo: Data {
        switch self {
        case .phoneToMac: return Data("remoteai/v1/phone-to-mac".utf8)
        case .macToPhone: return Data("remoteai/v1/mac-to-phone".utf8)
        }
    }
}

/// The pair of AES-256-GCM keys derived from one P-256 ECDH agreement.
public struct SessionKeys: @unchecked Sendable {
    public let phoneToMac: SymmetricKey
    public let macToPhone: SymmetricKey

    public init(phoneToMac: SymmetricKey, macToPhone: SymmetricKey) {
        self.phoneToMac = phoneToMac
        self.macToPhone = macToPhone
    }

    public static func derive(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey,
        salt: Data
    ) throws -> SessionKeys {
        return try derive(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            macId: "mac-1",
            deviceId: "phone-1"
        )
    }

    /// Derives the Rust Agent v1 directional keys using the frozen labels.
    public static func derive(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey,
        macId: String,
        deviceId: String
    ) throws -> SessionKeys {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let salt = Data("RemoteAI protocol v1".utf8)
        return SessionKeys(
            phoneToMac: shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("ios->mac|\(macId)|\(deviceId)".utf8),
                outputByteCount: 32
            ),
            macToPhone: shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("mac->ios|\(macId)|\(deviceId)".utf8),
                outputByteCount: 32
            )
        )
    }
}

/// One direction of the authenticated channel.
///
/// The counter and all routing metadata are authenticated: the counter through
/// the nonce, the metadata as AES-GCM associated data.
public struct CryptoBox: @unchecked Sendable {
    private let key: SymmetricKey
    private let direction: CryptoDirection

    public init(key: SymmetricKey, direction: CryptoDirection) {
        self.key = key
        self.direction = direction
    }

    public static func nonceBytes(direction: CryptoDirection, counter: UInt64) throws -> Data {
        var bytes = direction.noncePrefix
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }

    public func seal(_ plaintext: Data, counter: UInt64, aad: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: CryptoBox.nonceBytes(direction: direction, counter: counter))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        // Nonce is reconstructed from the counter, so only ciphertext+tag travel.
        return sealed.ciphertext + sealed.tag
    }

    public func open(_ frame: Data, counter: UInt64, aad: Data) throws -> Data {
        guard frame.count > 16 else { throw CryptoError.openFailed }
        let nonce = try AES.GCM.Nonce(data: CryptoBox.nonceBytes(direction: direction, counter: counter))
        let ciphertext = frame.prefix(frame.count - 16)
        let tag = frame.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw CryptoError.openFailed
        }
    }
}

/// Refuses any counter that is not strictly greater than the last accepted one.
public struct ReplayGuard: Sendable {
    public private(set) var lastCounter: UInt64

    public init(lastCounter: UInt64 = 0) {
        self.lastCounter = lastCounter
    }

    public mutating func accept(counter: UInt64) -> Bool {
        guard counter > lastCounter else { return false }
        lastCounter = counter
        return true
    }
}

/// Contents of the Mac's one-time pairing QR code.
///
/// It deliberately carries no vendor credential — only what is needed to reach
/// and authenticate the agent.
public struct PairingPayload: Codable, Sendable, Hashable {
    public let origin: String
    public let macId: String
    public let macPublicKey: Data
    public let pairingSecret: Data
    public let expiresAt: Date

    public init(
        origin: String, macId: String, macPublicKey: Data, pairingSecret: Data, expiresAt: Date
    ) {
        self.origin = origin
        self.macId = macId
        self.macPublicKey = macPublicKey
        self.pairingSecret = pairingSecret
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case origin, macId, macPublicKey, pairingSecret, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(String.self, forKey: .origin)
        macId = try container.decode(String.self, forKey: .macId)
        macPublicKey = try Self.decodeBytes(from: container, key: .macPublicKey)
        pairingSecret = try Self.decodeBytes(from: container, key: .pairingSecret)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encode(macId, forKey: .macId)
        try container.encode(macPublicKey.base64EncodedString(), forKey: .macPublicKey)
        try container.encode(pairingSecret.base64EncodedString(), forKey: .pairingSecret)
        try container.encode(expiresAt, forKey: .expiresAt)
    }

    private static func decodeBytes<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, key: K
    ) throws -> Data {
        if let encoded = try? container.decode(String.self, forKey: key) {
            if let base64 = Data(base64Encoded: encoded) { return base64 }
            return Data(encoded.utf8)
        }
        return Data(try container.decode([UInt8].self, forKey: key))
    }

    public static func decode(_ text: String) throws -> PairingPayload {
        guard let data = text.data(using: .utf8) else { throw CryptoError.malformedPairingPayload }
        do {
            return try ProtocolCoding.decoder.decode(PairingPayload.self, from: data)
        } catch {
            throw CryptoError.malformedPairingPayload
        }
    }

    public func validate(now: Date) throws {
        guard origin.hasPrefix("https://") else { throw CryptoError.insecureOrigin }
        guard now <= expiresAt else { throw CryptoError.pairingExpired }
        guard !macPublicKey.isEmpty, !pairingSecret.isEmpty else {
            throw CryptoError.malformedPairingPayload
        }
    }
}

/// Enforces that a pairing secret is consumed at most once on this device.
public final class UsedSecretRegistry: @unchecked Sendable {
    private var used: Set<Data> = []
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func claim(_ secret: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return used.insert(secret).inserted
    }
}

/// Everything this phone stores about its paired Mac.
///
/// There is no field for a Codex or Claude credential, and none may be added:
/// vendor secrets never leave the Mac.
public struct DeviceIdentity: Codable, Sendable, Hashable {
    public let macId: String
    public let origin: String
    public let privateKey: Data
    public let macPublicKey: Data

    public static let storedFieldNames = ["macId", "origin", "privateKey", "macPublicKey"]

    public init(macId: String, origin: String, privateKey: Data, macPublicKey: Data) {
        self.macId = macId
        self.origin = origin
        self.privateKey = privateKey
        self.macPublicKey = macPublicKey
    }
}

public protocol SecretStore: Sendable {
    func save(_ identity: DeviceIdentity) throws
    func load() throws -> DeviceIdentity?
    func deleteAll() throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var identity: DeviceIdentity?
    private let lock = NSLock()

    public init() {}

    public func save(_ identity: DeviceIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        self.identity = identity
    }

    public func load() throws -> DeviceIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identity
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        identity = nil
    }
}
