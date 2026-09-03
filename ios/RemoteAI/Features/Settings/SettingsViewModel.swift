import Foundation
import Observation

/// Backs the Settings tab: connection facts, audit trail, cache and revocation.
@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var diagnostics: Diagnostics?
    public private(set) var auditEntries: [AuditEntry] = []
    public private(set) var isRevoked = false
    public private(set) var errorMessage: String?

    private let client: AgentClient
    private let cache: CatalogCache
    private let store: SecretStore

    public init(client: AgentClient, cache: CatalogCache, store: SecretStore) {
        self.client = client
        self.cache = cache
        self.store = store
    }

    public func reload(auditLimit: Int = 100) async {
        do {
            diagnostics = try await client.diagnostics()
            auditEntries = try await client.listAudit(limit: auditLimit)
                .sorted { $0.timestamp > $1.timestamp }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func clearCache() async {
        cache.clear()
    }

    /// Destructive: the phone loses access until it is paired again, so the
    /// caller must pass an explicit confirmation.
    public func revokeDevice(confirmed: Bool) async {
        guard confirmed else { return }
        do {
            try await client.revokeDevice()
            try store.deleteAll()
            cache.clear()
            isRevoked = true
        } catch {
            errorMessage = "\(error)"
        }
    }
}
