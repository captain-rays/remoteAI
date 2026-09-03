import Foundation
import Security

/// Keychain-backed `SecretStore` used by the shipping app.
///
/// NOT covered by the SwiftPM suites: exercising it requires a real keychain,
/// which is only available under a signed test host. `InMemorySecretStore` is
/// the tested reference implementation of the same contract; this type must be
/// verified during integration on device.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "live.jaco.remoteai", account: String = "device-identity") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ identity: DeviceIdentity) throws {
        let data = try ProtocolCoding.encoder.encode(identity)
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // Device-only: the paired key must never ride an iCloud or device backup.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentClientError.transport("keychain_add_failed:\(status)")
        }
    }

    public func load() throws -> DeviceIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AgentClientError.transport("keychain_read_failed:\(status)")
        }
        return try ProtocolCoding.decoder.decode(DeviceIdentity.self, from: data)
    }

    public func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentClientError.transport("keychain_delete_failed:\(status)")
        }
    }
}
