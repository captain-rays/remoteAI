import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum ConversationViewModelSuite {

    static let conversation = ConversationSummary(
        id: "codex-daily-1", provider: .codex, kind: .daily,
        title: "Shell one-liners",
        updatedAt: Date(timeIntervalSince1970: 1_788_000_000), status: .idle
    )

    @MainActor
    static func makeViewModel(
        client: any AgentClient = MockAgentClient(),
        online: Bool = true
    ) -> ConversationViewModel {
        let model = ConversationViewModel(conversation: conversation, client: client)
        model.isOnline = online
        return model
    }

    static func event(
        _ sequence: Int, _ raw: String, _ event: ConversationEvent
    ) -> EventEnvelope {
        EventEnvelope(
            sequence: sequence, conversationId: conversation.id, rawType: raw, event: event
        )
    }

    static func delta(_ sequence: Int, _ text: String, id: String = "a1") -> EventEnvelope {
        event(
            sequence, "conversation.delta",
            .delta(MessagePayload(messageId: id, role: .assistant, text: text))
        )
    }

    public static let suite = TestSuite(
        name: "ConversationViewModelSuite",
        cases: [
            TestCase("deltas assemble in order into a single streaming message") {
                let model = await makeViewModel()
                await model.handle(delta(1, "Hel"))
                await model.handle(delta(2, "lo "))
                await model.handle(delta(3, "world"))

                let messages = await model.messages
                try expectEqual(messages.count, 1)
                try expectEqual(messages[0].text, "Hello world")
                try expectTrue(messages[0].isStreaming)
            },

            TestCase("a replayed delta does not duplicate text") {
                let model = await makeViewModel()
                await model.handle(delta(1, "Hel"))
                await model.handle(delta(2, "lo"))
                await model.handle(delta(2, "lo"))

                try expectEqual(await model.messages[0].text, "Hello")
            },

            TestCase("a completed message stops streaming and keeps the final text") {
                let model = await makeViewModel()
                await model.handle(delta(1, "Hel"))
                await model.handle(
                    event(
                        2, "conversation.message_completed",
                        .messageCompleted(
                            MessagePayload(messageId: "a1", role: .assistant, text: "Hello")
                        )
                    )
                )
                let messages = await model.messages
                try expectEqual(messages.count, 1)
                try expectEqual(messages[0].text, "Hello")
                try expectFalse(messages[0].isStreaming)
            },

            TestCase("tool events appear once and update in place") {
                let model = await makeViewModel()
                await model.handle(
                    event(
                        1, "tool.started",
                        .toolStarted(ToolPayload(toolCallId: "t1", name: "shell", status: "running"))
                    )
                )
                await model.handle(
                    event(
                        2, "tool.completed",
                        .toolCompleted(
                            ToolPayload(
                                toolCallId: "t1", name: "shell", detail: "exit 0", status: "done"
                            )
                        )
                    )
                )
                let tools = await model.tools
                try expectEqual(tools.count, 1, "the same tool call must not appear twice")
                try expectEqual(tools[0].status, "done")
                try expectEqual(tools[0].detail, "exit 0")
            },

            TestCase("the stop control is offered only while a turn is running") {
                let model = await makeViewModel()
                try expectFalse(await model.canStop)

                await model.handle(delta(1, "working"))
                try expectTrue(await model.canStop)

                await model.handle(
                    event(2, "turn.completed", .turnCompleted(TurnPayload(turnId: "t")))
                )
                try expectFalse(await model.canStop)
            },

            TestCase("an approval request offers exactly allow_once and deny") {
                let model = await makeViewModel()
                await model.handle(
                    event(
                        1, "approval.requested",
                        .approvalRequested(
                            ApprovalRequest(
                                id: "ap1", provider: .codex, conversationId: conversation.id,
                                category: .command, title: "Run", detail: "rm -rf build/",
                                cwd: "/Users/dev", risk: .high,
                                createdAt: Date(timeIntervalSince1970: 1_788_000_000)
                            )
                        )
                    )
                )
                let pending = try expectNotNil(await model.pendingApproval)
                try expectEqual(pending.id, "ap1")
                try expectEqual(
                    await model.availableDecisions, [.allowOnce, .deny],
                    "a permanent allow must never be offered"
                )
            },

            TestCase("resolving an approval clears the card") {
                let model = await makeViewModel()
                await model.handle(
                    event(
                        1, "approval.requested",
                        .approvalRequested(
                            ApprovalRequest(
                                id: "ap1", provider: .codex, conversationId: conversation.id,
                                category: .command, title: "Run", detail: "ls",
                                cwd: nil, risk: .low,
                                createdAt: Date(timeIntervalSince1970: 1_788_000_000)
                            )
                        )
                    )
                )
                await model.handle(
                    event(
                        2, "approval.resolved",
                        .approvalResolved(ApprovalResolution(id: "ap1", decision: .deny))
                    )
                )
                try expectNil(await model.pendingApproval)
            },

            TestCase("a failed turn surfaces an error and ends the run") {
                let model = await makeViewModel()
                await model.handle(delta(1, "working"))
                await model.handle(
                    event(
                        2, "turn.failed",
                        .turnFailed(
                            TurnFailure(turnId: "t", code: "cli_crashed", message: "codex exited")
                        )
                    )
                )
                try expectFalse(await model.canStop)
                try expectEqual(await model.errors.count, 1)
                try expectEqual(await model.errors[0].code, "cli_crashed")
            },

            TestCase("an unsupported event adds nothing to the timeline") {
                let model = await makeViewModel()
                await model.handle(delta(1, "hi"))
                let before = await model.items.count
                await model.handle(
                    event(2, "conversation.telepathy", .unsupported(rawType: "conversation.telepathy"))
                )
                try expectEqual(await model.items.count, before)
            },

            TestCase("sending while offline fails the draft and offers a retry") {
                let model = await makeViewModel(online: false)
                await model.send("hello")

                try expectEqual(await model.failedDraft, "hello")
                try expectTrue(await model.canRetry)
                try expectEqual(await model.errors.count, 1)
                let user = try expectNotNil(await model.messages.first)
                try expectEqual(user.role, .user)
                try expectEqual(user.text, "hello")
                try expectEqual(user.deliveryState, .failed)
            },

            TestCase("send appends a sending user item before the agent acknowledges") {
                let client = ControlledSendClient(mode: .suspended)
                let model = await makeViewModel(client: client)

                let send = Task { await model.send("hello") }
                await client.waitUntilSendStarts()

                let user = try expectNotNil(await model.messages.first)
                try expectEqual(user.role, .user)
                try expectEqual(user.text, "hello")
                try expectEqual(user.deliveryState, .sending)

                await client.releaseSend()
                await send.value
                try expectEqual(await model.messages.first?.deliveryState, .sent)
            },

            TestCase("retrying a failed send clears the draft once it succeeds") {
                let client = MockAgentClient()
                let model = await makeViewModel(client: client, online: false)
                await model.send("hello")
                try expectTrue(await model.canRetry)

                await MainActor.run { model.isOnline = true }
                await model.retryFailedSend()

                try expectNil(await model.failedDraft)
                try expectFalse(await model.canRetry)
                let users = await model.messages.filter { $0.role == .user }
                try expectEqual(users.count, 1, "retry must update the same optimistic item")
                try expectEqual(users[0].deliveryState, .sent)
            },

            TestCase("session busy preserves the failed user item and safe block message") {
                let client = ControlledSendClient(
                    mode: .failure(.rejected("session_busy"))
                )
                let model = await makeViewModel(client: client)

                await model.send("keep this draft")

                try expectEqual(await model.failedDraft, "keep this draft")
                let user = try expectNotNil(await model.messages.first)
                try expectEqual(user.deliveryState, .failed)
                let error = try expectNotNil(await model.errors.last)
                try expectEqual(error.code, "session_busy")
                try expectEqual(
                    error.message,
                    "This conversation is active elsewhere. You can view its history, but cannot send."
                )
            },

            TestCase("stopping is refused when no turn is running") {
                let model = await makeViewModel()
                await model.stop()
                try expectEqual(await model.errors.count, 0, "a no-op stop must not raise an error")
            },

            TestCase("history is loaded from the agent and replayed in order") {
                let client = MockAgentClient()
                try await client.send(
                    provider: .codex, conversationId: conversation.id, text: "hello"
                )

                let model = await makeViewModel(client: client)
                await model.loadHistory()

                let messages = await model.messages
                try expectTrue(messages.count >= 2, "user and assistant messages")
                try expectEqual(messages.first?.role, .user)
                try expectFalse(await model.canStop, "a replayed completed turn is not running")
            },

            TestCase("opening and streaming a conversation issues no transfer request") {
                let client = MockAgentClient()
                let model = await makeViewModel(client: client)
                await model.loadHistory()
                await model.send("hello")

                try expectEqual(await client.transferRequestCount, 0)
            },
        ]
    )
}

private actor ControlledSendClient: AgentClient {
    enum Mode: Sendable {
        case suspended
        case failure(AgentClientError)
    }

    nonisolated let events = AsyncStream<EventEnvelope> { continuation in
        continuation.finish()
    }

    private let mode: Mode
    private var sendStarted = false
    private var sendContinuation: CheckedContinuation<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
    }

    func waitUntilSendStarts() async {
        while !sendStarted { await Task.yield() }
    }

    func releaseSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }

    func send(provider: ProviderId, conversationId: String, text: String) async throws {
        sendStarted = true
        switch mode {
        case .suspended:
            await withCheckedContinuation { sendContinuation = $0 }
        case let .failure(error):
            throw error
        }
    }

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
    func listAudit(limit: Int) async throws -> [AuditEntry] { throw AgentClientError.offline }
    func diagnostics() async throws -> Diagnostics { throw AgentClientError.offline }
    func revokeDevice() async throws { throw AgentClientError.offline }
}
