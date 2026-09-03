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
                payload: payload, phonePublicKey: phoneKey.publicKey.rawRepresentation
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
