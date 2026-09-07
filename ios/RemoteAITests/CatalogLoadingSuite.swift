import Foundation
import RemoteAIKit
import RemoteAITestKit

/// Catalog reads are slow enough to see: the agent re-indexes the provider on
/// every catalog request, and Codex goes out to its app-server for it. Without
/// a load state the list renders its "nothing here" message while the answer is
/// still in flight, so the screen looks empty and then pops.
public enum CatalogLoadingSuite {

    @MainActor
    static func makeModel(client: AgentClient) -> AppModel {
        AppModel(
            client: client,
            preferences: InMemoryPreferencesStore(),
            cache: InMemoryCatalogCache()
        )
    }

    public static let suite = TestSuite(
        name: "CatalogLoadingSuite",
        cases: [
            TestCase("a model that has never loaded is busy, not empty") {
                let model = await makeModel(client: MockAgentClient())
                try expectTrue(await model.isLoadingCatalog, "a fresh screen must show progress")
                try expectFalse(
                    await model.showsEmptyProjects,
                    "an unloaded catalog must not claim the provider has no projects"
                )
            },

            TestCase("the catalog is busy while the agent is still answering") {
                let client = GatedCatalogClient()
                let model = await makeModel(client: client)
                await model.setConnectionState(.online)

                let load = Task { await model.reloadCatalog() }
                await client.waitUntilBlocked()
                try expectTrue(await model.isLoadingCatalog)
                try expectFalse(await model.showsEmptyProjects)

                await client.release()
                await load.value
                try expectFalse(await model.isLoadingCatalog)
                try expectFalse(await model.projects.isEmpty)
            },

            TestCase("a provider with no projects reports empty only once loaded") {
                let client = GatedCatalogClient(projects: [])
                let model = await makeModel(client: client)
                await model.setConnectionState(.online)

                let load = Task { await model.reloadCatalog() }
                await client.waitUntilBlocked()
                try expectFalse(await model.showsEmptyProjects, "still loading")
                await client.release()
                await load.value

                try expectTrue(await model.showsEmptyProjects, "now it is genuinely empty")
            },

            TestCase("a failed catalog stops the spinner instead of hanging") {
                let client = GatedCatalogClient(failure: .transport("boom"))
                let model = await makeModel(client: client)
                await model.setConnectionState(.online)

                let load = Task { await model.reloadCatalog() }
                await client.waitUntilBlocked()
                await client.release()
                await load.value

                try expectFalse(await model.isLoadingCatalog, "a failure must not spin forever")
                _ = try expectNotNil(await model.lastErrorMessage)
            },

            TestCase("switching provider shows progress rather than a stale empty state") {
                let model = await makeModel(client: MockAgentClient())
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                try expectFalse(await model.isLoadingCatalog)

                await model.prepareProviderSwitch(to: .claude)
                try expectTrue(
                    await model.isLoadingCatalog,
                    "the new provider has not been read yet"
                )
                try expectFalse(await model.showsEmptyProjects)
            },
        ]
    )
}

/// Blocks `listProjects` until released, so the loading state is observable.
private actor GatedCatalogClient: StubAgentClient {
    nonisolated let events = AsyncStream<EventEnvelope> { $0.finish() }

    private let projects: [ProjectSummary]
    private let failure: AgentClientError?
    private var blocked = false
    private var gate: CheckedContinuation<Void, Never>?

    init(projects: [ProjectSummary]? = nil, failure: AgentClientError? = nil) {
        self.projects = projects ?? [
            ProjectSummary(
                id: "codex:/tmp/a", provider: .codex, canonicalPath: "/tmp/a",
                displayPath: "/tmp/a", title: "a",
                updatedAt: Date(timeIntervalSince1970: 1_788_000_000), available: true
            )
        ]
        self.failure = failure
    }

    func waitUntilBlocked() async {
        while !blocked { await Task.yield() }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func providerStatus() async throws -> [ProviderStatus] { [] }

    func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] { [] }

    func listProjects(provider: ProviderId) async throws -> [ProjectSummary] {
        blocked = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate = continuation
        }
        blocked = false
        if let failure { throw failure }
        return projects
    }

    func listProjectConversations(
        provider: ProviderId, projectId: String
    ) async throws -> [ConversationSummary] { [] }
    func history(
        provider: ProviderId, conversationId: String, cursor: String?, limit: Int
    ) async throws -> HistoryPage { throw AgentClientError.offline }
    func startConversation(
        provider: ProviderId, kind: ConversationKind, cwd: String?
    ) async throws -> ConversationSummary { throw AgentClientError.offline }
    func resumeConversation(provider: ProviderId, conversationId: String) async throws {}
    func send(provider: ProviderId, conversationId: String, text: String) async throws {}
    func interrupt(provider: ProviderId, conversationId: String) async throws {}
    func decideApproval(id: String, decision: ApprovalDecision) async throws {}
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
    func uploadChunk(transferId: String, index: Int, data: Data) async throws {}
    func downloadChunk(transferId: String, index: Int) async throws -> Data {
        throw AgentClientError.offline
    }
    func finishTransfer(transferId: String) async throws -> TransferReceipt {
        throw AgentClientError.offline
    }
    func cancelTransfer(transferId: String) async throws {}
    func listAudit(limit: Int) async throws -> [AuditEntry] { [] }
    func diagnostics() async throws -> Diagnostics { throw AgentClientError.offline }
    func revokeDevice() async throws {}
}
