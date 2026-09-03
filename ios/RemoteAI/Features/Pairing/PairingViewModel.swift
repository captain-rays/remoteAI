import CryptoKit
import Foundation
import Observation

public enum PairingState: Sendable, Hashable {
    case idle
    case pairing
    case paired
    case failed(String)
}

/// Completes the handshake with the Mac after the QR code has been validated.
public protocol PairingService: Sendable {
    func completePairing(
        payload: PairingPayload, phonePublicKey: Data
    ) async throws -> Bool
}

public enum RemotePairingError: Error, Equatable, Sendable {
    case invalidOrigin
    case invalidSecret
    case invalidResponse
    case httpStatus(Int)
}

/// URLSession-backed pairing against the Agent's public `/v1/pair` endpoint.
/// The QR secret is sent only in the request body and is never logged or
/// persisted by this service.
public final class RemotePairingService: PairingService, @unchecked Sendable {
    private struct PairRequest: Encodable {
        let pairingSecret: String
        let deviceId: String
        let deviceLabel: String
        let devicePublicKey: [UInt8]
    }

    private let origin: URL
    private let session: URLSession
    private let deviceId: String?
    private let deviceLabel: String

    public init(
        origin: URL,
        deviceId: String? = nil,
        deviceLabel: String = "iPhone",
        session: URLSession = .shared
    ) {
        self.origin = origin
        self.session = session
        self.deviceId = deviceId
        self.deviceLabel = deviceLabel
    }

    /// Stable identifier derived from public key material, so reconnecting
    /// after relaunch authenticates as the same paired device without storing
    /// another identifier alongside the private key.
    public static func deterministicDeviceId(publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return "phone-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func makePairRequest(
        origin: URL,
        payload: PairingPayload,
        deviceId: String,
        deviceLabel: String,
        phonePublicKey: Data
    ) throws -> URLRequest {
        guard ["http", "https"].contains(origin.scheme?.lowercased()), origin.host != nil,
            origin.user == nil, origin.password == nil
        else { throw RemotePairingError.invalidOrigin }
        guard let secret = String(data: payload.pairingSecret, encoding: .utf8), !secret.isEmpty
        else { throw RemotePairingError.invalidSecret }

        let endpoint = origin.appendingPathComponent("v1/pair")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PairRequest(
                pairingSecret: secret,
                deviceId: deviceId,
                deviceLabel: deviceLabel,
                devicePublicKey: Array(phonePublicKey)
            )
        )
        return request
    }

    public func completePairing(
        payload: PairingPayload, phonePublicKey: Data
    ) async throws -> Bool {
        let request = try Self.makePairRequest(
            origin: origin,
            payload: payload,
            deviceId: deviceId ?? Self.deterministicDeviceId(publicKey: phonePublicKey),
            deviceLabel: deviceLabel,
            phonePublicKey: phonePublicKey
        )
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemotePairingError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw RemotePairingError.httpStatus(http.statusCode)
        }
        return true
    }
}

public final class MockPairingService: PairingService, @unchecked Sendable {
    private let shouldSucceed: Bool

    public init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    public func completePairing(payload: PairingPayload, phonePublicKey: Data) async throws -> Bool {
        shouldSucceed
    }
}

/// Scans and validates a one-time pairing code, then stores the device key.
///
/// The private key is generated on the phone and never leaves it; the QR code
/// carries no vendor credential, so nothing about Codex or Claude is stored.
@MainActor
@Observable
public final class PairingViewModel {
    public private(set) var state: PairingState = .idle
    /// App-level hook used to transition the connection coordinator after the
    /// handshake. It is nil in isolated tests and the mock pairing path.
    public var onPaired: (@MainActor @Sendable () -> Void)?

    private let store: SecretStore
    private let registry: UsedSecretRegistry
    private let service: PairingService
    private let now: @Sendable () -> Date

    public init(
        store: SecretStore,
        registry: UsedSecretRegistry,
        service: PairingService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.registry = registry
        self.service = service
        self.now = now
    }

    public func pair(scannedText: String) async {
        state = .pairing

        let payload: PairingPayload
        do {
            payload = try PairingPayload.decode(scannedText)
            try payload.validate(now: now())
        } catch let error as CryptoError {
            state = .failed(PairingViewModel.message(for: error))
            return
        } catch {
            state = .failed(PairingViewModel.message(for: .malformedPairingPayload))
            return
        }

        // Single use: claim before contacting the Mac so a retry cannot replay.
        guard registry.claim(payload.pairingSecret) else {
            state = .failed(PairingViewModel.message(for: .secretAlreadyUsed))
            return
        }

        let phoneKey = P256.KeyAgreement.PrivateKey()
        do {
            let accepted = try await service.completePairing(
                payload: payload, phonePublicKey: phoneKey.publicKey.x963Representation
            )
            guard accepted else {
                state = .failed("The Mac refused this pairing code.")
                return
            }
            try store.save(
                DeviceIdentity(
                    macId: payload.macId,
                    origin: payload.origin,
                    privateKey: phoneKey.rawRepresentation,
                    macPublicKey: payload.macPublicKey
                )
            )
            state = .paired
            onPaired?()
        } catch let error as RemotePairingError {
            if case let .httpStatus(code) = error {
                state = .failed("Pairing request failed (HTTP \(code)).")
            } else {
                state = .failed("Pairing could not be completed.")
            }
        } catch {
            state = .failed("Pairing could not be completed.")
        }
    }

    public func revoke() async {
        try? store.deleteAll()
        state = .idle
    }

    static func message(for error: CryptoError) -> String {
        switch error {
        case .pairingExpired: return "This pairing code has expired."
        case .insecureOrigin: return "This Mac address is not encrypted."
        case .secretAlreadyUsed: return "This pairing code has already been used."
        case .malformedPairingPayload: return "This is not a RemoteAI pairing code."
        case .replayedCounter, .sealFailed, .openFailed:
            return "The secure channel could not be established."
        }
    }
}
