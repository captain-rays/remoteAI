import Foundation

// MARK: - Supporting request/response types

public struct HistoryPage: Sendable, Hashable {
    public let events: [EventEnvelope]
    public let hasMore: Bool
    public let nextCursor: String?

    public init(events: [EventEnvelope], hasMore: Bool, nextCursor: String?) {
        self.events = events
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

public struct DirectoryListing: Sendable, Hashable {
    public let path: String
    public let parentPath: String?
    public let entries: [FileEntry]

    public init(path: String, parentPath: String?, entries: [FileEntry]) {
        self.path = path
        self.parentPath = parentPath
        self.entries = entries
    }
}

public struct FilePreview: Sendable, Hashable {
    public let path: String
    public let text: String?
    public let byteCount: Int
    public let truncated: Bool

    public init(path: String, text: String?, byteCount: Int, truncated: Bool) {
        self.path = path
        self.text = text
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public enum TransferDirection: String, Codable, Sendable, Hashable {
    case upload
    case download
}

/// The only two ways a same-name upload may be resolved. There is deliberately
/// no "decide automatically" case.
public enum ConflictPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case keepBoth = "keep_both"
    case overwrite
}

public struct TransferRequest: Sendable, Hashable {
    public let direction: TransferDirection
    public let name: String
    public let remoteDirectory: String
    public let byteCount: Int64
    public let conflictPolicy: ConflictPolicy?

    public init(
        direction: TransferDirection,
        name: String,
        remoteDirectory: String,
        byteCount: Int64,
        conflictPolicy: ConflictPolicy?
    ) {
        self.direction = direction
        self.name = name
        self.remoteDirectory = remoteDirectory
        self.byteCount = byteCount
        self.conflictPolicy = conflictPolicy
    }
}

public struct TransferConflict: Sendable, Hashable {
    public let existingPath: String
    public let existingSize: Int64?

    public init(existingPath: String, existingSize: Int64?) {
        self.existingPath = existingPath
        self.existingSize = existingSize
    }
}

public struct TransferTicket: Sendable, Hashable, Identifiable {
    public let id: String
    public let destinationPath: String
    public let chunkSize: Int
    public let totalChunks: Int
    /// Non-nil when the caller must present a `keep_both` / `overwrite` choice
    /// before any byte is written. A ticket with a conflict is not writable.
    public let conflict: TransferConflict?

    public init(
        id: String,
        destinationPath: String,
        chunkSize: Int,
        totalChunks: Int,
        conflict: TransferConflict?
    ) {
        self.id = id
        self.destinationPath = destinationPath
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.conflict = conflict
    }
}

public struct TransferReceipt: Sendable, Hashable {
    public let id: String
    public let finalPath: String
    public let sha256: String

    public init(id: String, finalPath: String, sha256: String) {
        self.id = id
        self.finalPath = finalPath
        self.sha256 = sha256
    }
}

public struct AuditEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let action: String
    public let provider: ProviderId?
    public let conversationId: String?
    public let targetPath: String?
    public let outcome: String

    public init(
        id: String,
        timestamp: Date,
        action: String,
        provider: ProviderId?,
        conversationId: String?,
        targetPath: String?,
        outcome: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.provider = provider
        self.conversationId = conversationId
        self.targetPath = targetPath
        self.outcome = outcome
    }
}

public struct Diagnostics: Sendable, Hashable {
    public let agentVersion: String
    public let macOSVersion: String
    public let cloudflaredVersion: String?
    public let endpoint: String
    public let tunnelHealthy: Bool
    public let providers: [ProviderStatus]

    public init(
        agentVersion: String,
        macOSVersion: String,
        cloudflaredVersion: String?,
        endpoint: String,
        tunnelHealthy: Bool,
        providers: [ProviderStatus]
    ) {
        self.agentVersion = agentVersion
        self.macOSVersion = macOSVersion
        self.cloudflaredVersion = cloudflaredVersion
        self.endpoint = endpoint
        self.tunnelHealthy = tunnelHealthy
        self.providers = providers
    }
}

public enum AgentClientError: Error, Equatable, Sendable {
    case offline
    case notPaired
    case providerMismatch
    case notFound(String)
    case rejected(String)
    case invalidRequest(String)
    case transport(String)
}

// MARK: - Client contract

/// Everything the UI is allowed to ask the Mac agent for.
///
/// Provider scoping is part of the contract: every catalog call takes an
/// explicit `ProviderId` and implementations must reject cross-provider
/// requests rather than silently returning a merged result.
public protocol AgentClient: Sendable {
    /// Realtime event feed. Single-consumer by design; `AppModel` fans out.
    var events: AsyncStream<EventEnvelope> { get async }

    func providerStatus() async throws -> [ProviderStatus]

    func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary]
    func listProjects(provider: ProviderId) async throws -> [ProjectSummary]
    func listProjectConversations(
        provider: ProviderId, projectId: String
    ) async throws -> [ConversationSummary]

    func history(
        provider: ProviderId, conversationId: String, cursor: String?, limit: Int
    ) async throws -> HistoryPage

    func startConversation(
        provider: ProviderId, kind: ConversationKind, cwd: String?
    ) async throws -> ConversationSummary
    func resumeConversation(provider: ProviderId, conversationId: String) async throws
    func send(provider: ProviderId, conversationId: String, text: String) async throws
    func interrupt(provider: ProviderId, conversationId: String) async throws

    func decideApproval(id: String, decision: ApprovalDecision) async throws

    /// Returns the agent's default browsing directory (typically the user's home).
    /// The client owns this path so the UI never hardcodes a machine-specific home.
    func initialDirectory() async throws -> DirectoryListing
    func listFiles(path: String, showHidden: Bool) async throws -> DirectoryListing
    func filePreview(path: String, maxBytes: Int) async throws -> FilePreview

    /// Every transfer entry point is explicit; there is no watcher, timer, or
    /// lifecycle hook anywhere in this protocol.
    func createTransfer(_ request: TransferRequest) async throws -> TransferTicket
    func uploadChunk(transferId: String, index: Int, data: Data) async throws
    func downloadChunk(transferId: String, index: Int) async throws -> Data
    func finishTransfer(transferId: String) async throws -> TransferReceipt
    func cancelTransfer(transferId: String) async throws

    func listAudit(limit: Int) async throws -> [AuditEntry]
    func diagnostics() async throws -> Diagnostics
    func revokeDevice() async throws
}
