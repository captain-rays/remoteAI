import Foundation
@testable import RemoteAIKit

/// An `AgentClient` whose every call fails, so a stub only writes the one or
/// two methods its test is about.
///
/// The protocol has forty-odd methods and a test usually cares about one of
/// them. Hand-rolling the rest buries the interesting line in boilerplate, and
/// a stub that quietly returns an empty success for a call the test did not
/// expect hides bugs. Defaulting to `offline` means an unexpected call fails
/// the test instead.
protocol StubAgentClient: AgentClient {}

extension StubAgentClient {
    var events: AsyncStream<EventEnvelope> { AsyncStream { $0.finish() } }

    func providerStatus() async throws -> [ProviderStatus] { throw AgentClientError.offline }

    func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] {
        throw AgentClientError.offline
    }
    func listProjects(provider: ProviderId) async throws -> [ProjectSummary] {
        throw AgentClientError.offline
    }
    func listProjectConversations(
        provider: ProviderId, projectId: String
    ) async throws -> [ConversationSummary] { throw AgentClientError.offline }

    func history(
        provider: ProviderId, conversationId: String, cursor: String?, limit: Int
    ) async throws -> HistoryPage { throw AgentClientError.offline }

    func startConversation(
        provider: ProviderId, kind: ConversationKind, cwd: String?
    ) async throws -> ConversationSummary { throw AgentClientError.offline }
    func resumeConversation(provider: ProviderId, conversationId: String) async throws {
        throw AgentClientError.offline
    }
    func send(
        provider: ProviderId, conversationId: String, text: String, attachments: [String]
    ) async throws {
        throw AgentClientError.offline
    }
    func interrupt(provider: ProviderId, conversationId: String) async throws {
        throw AgentClientError.offline
    }

    func decideApproval(id: String, decision: ApprovalDecision) async throws {
        throw AgentClientError.offline
    }

    func initialDirectory() async throws -> DirectoryListing { throw AgentClientError.offline }
    func listFiles(path: String, showHidden: Bool) async throws -> DirectoryListing {
        throw AgentClientError.offline
    }
    func filePreview(path: String, maxBytes: Int) async throws -> FilePreview {
        throw AgentClientError.offline
    }

    func createTransfer(_ request: TransferRequest) async throws -> TransferTicket {
        throw AgentClientError.offline
    }
    func uploadChunk(transferId: String, index: Int, data: Data) async throws {
        throw AgentClientError.offline
    }
    func downloadChunk(transferId: String, index: Int) async throws -> Data {
        throw AgentClientError.offline
    }
    func finishTransfer(transferId: String) async throws -> TransferReceipt {
        throw AgentClientError.offline
    }
    func cancelTransfer(transferId: String) async throws { throw AgentClientError.offline }

    func accounts(provider: ProviderId) async throws -> AccountsView {
        throw AgentClientError.offline
    }
    func saveAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        throw AgentClientError.offline
    }
    func deleteAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        throw AgentClientError.offline
    }
    func activateAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        throw AgentClientError.offline
    }
    func logout(provider: ProviderId) async throws -> AccountsView {
        throw AgentClientError.offline
    }
    func startLogin(provider: ProviderId, label: String?) async throws -> LoginProgress {
        throw AgentClientError.offline
    }
    func loginProgress(provider: ProviderId) async throws -> LoginProgress? {
        throw AgentClientError.offline
    }
    func sendLoginInput(provider: ProviderId, sessionId: String, text: String) async throws {
        throw AgentClientError.offline
    }
    func cancelLogin(provider: ProviderId, sessionId: String) async throws {
        throw AgentClientError.offline
    }

    func speechCredentials() async throws -> SpeechCredentials {
        throw AgentClientError.offline
    }

    func listAudit(limit: Int) async throws -> [AuditEntry] { throw AgentClientError.offline }
    func diagnostics() async throws -> Diagnostics { throw AgentClientError.offline }
    func revokeDevice() async throws { throw AgentClientError.offline }
}
