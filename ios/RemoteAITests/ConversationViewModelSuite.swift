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
        online: Bool = true,
        cache: CatalogCache? = nil
    ) -> ConversationViewModel {
        let model = ConversationViewModel(
            conversation: conversation,
            client: client,
            cache: cache
        )
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

    /// Waits for one specific event off a stream, giving up after a short wait
    /// so a broken fan-out fails the test instead of hanging it.
    static func waitForEvent(
        _ stream: AsyncStream<EventEnvelope>, rawType: String
    ) -> Task<Bool, Never> {
        let waiter = Task { () -> Bool in
            for await envelope in stream where envelope.rawType == rawType {
                return true
            }
            return false
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            waiter.cancel()
        }
        return waiter
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

            TestCase("reasoning streams in place and is collapsed by default") {
                let model = await makeViewModel()
                await model.handle(
                    event(
                        1,
                        "conversation.reasoning_delta",
                        .reasoningDelta(ReasoningPayload(reasoningId: "r1", text: "First "))
                    )
                )
                await model.handle(
                    event(
                        2,
                        "conversation.reasoning_delta",
                        .reasoningDelta(ReasoningPayload(reasoningId: "r1", text: "second"))
                    )
                )

                let reasoning = try expectNotNil(await model.reasoning.first)
                try expectEqual(reasoning.text, "First second")
                try expectTrue(reasoning.isStreaming)
                try expectFalse(reasoning.isExpanded)
            },

            TestCase("reasoning completion replaces text and stops streaming") {
                let model = await makeViewModel()
                await model.handle(
                    event(
                        1,
                        "conversation.reasoning_delta",
                        .reasoningDelta(ReasoningPayload(reasoningId: "r1", text: "partial"))
                    )
                )
                await model.handle(
                    event(
                        2,
                        "conversation.reasoning_completed",
                        .reasoningCompleted(ReasoningPayload(reasoningId: "r1", text: "complete"))
                    )
                )

                let reasoning = try expectNotNil(await model.reasoning.first)
                try expectEqual(reasoning.text, "complete")
                try expectFalse(reasoning.isStreaming)
                try expectFalse(reasoning.isExpanded)
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

            TestCase("a message carries the files that were attached to it") {
                // The provider is handed paths, not bytes, and the reader
                // must be able to see afterwards what was attached — a
                // transcript that shows only the text leaves them guessing
                // whether the file went at all.
                let client = RecordingSendClient()
                let model = await makeViewModel(client: client)
                let path = "/Users/dev/work/api/.remoteai/uploads/shot.jpeg"

                await model.send("what is this", attachments: [path])

                try expectEqual(await client.sentAttachments, [path])
                let mine = try expectNotNil(
                    await model.messages.last { $0.role == .user }
                )
                try expectEqual(mine.attachments, [path])
            },

            TestCase("an attachment-only message is still worth sending") {
                // A photo with no words is a complete instruction: "look at
                // this". Refusing it would make the reader type a space.
                let client = RecordingSendClient()
                let model = await makeViewModel(client: client)

                await model.send("", attachments: ["/Users/dev/work/api/.remoteai/uploads/a.png"])

                try expectEqual(await client.sendCount, 1)
            },

            TestCase("a message with neither words nor files is not sent") {
                let client = RecordingSendClient()
                let model = await makeViewModel(client: client)

                await model.send("   ", attachments: [])

                try expectEqual(await client.sendCount, 0)
            },

            TestCase("a retry sends the files the failed message named") {
                // The file is already on the Mac; dropping its path on retry
                // would send the words alone and the answer would be about
                // nothing.
                let client = FailThenRecordClient()
                let model = await makeViewModel(client: client)
                let path = "/Users/dev/work/api/.remoteai/uploads/shot.jpeg"

                await model.send("what is this", attachments: [path])
                await model.retryFailedSend()

                try expectEqual(await client.sentAttachments, [path])
            },

            TestCase("two open conversations each receive every event") {
                // One AsyncStream hands each element to exactly one consumer,
                // so a second open transcript silently eats the first one's
                // events. Both must see the same single user_message event.
                let client = MockAgentClient()
                let first = await makeViewModel(client: client)
                let second = await makeViewModel(client: client)

                let firstSaw = waitForEvent(
                    await first.eventStream(), rawType: "conversation.user_message"
                )
                let secondSaw = waitForEvent(
                    await second.eventStream(), rawType: "conversation.user_message"
                )

                try await client.send(
                    provider: .codex, conversationId: conversation.id, text: "ping"
                )

                try expectTrue(await firstSaw.value, "the first transcript missed the event")
                try expectTrue(await secondSaw.value, "the second transcript missed the event")
            },

            TestCase("a provider echo of the user turn reconciles with the local bubble") {
                let client = ControlledSendClient(mode: .history([]))
                let model = await makeViewModel(client: client)
                await model.send("ship it")

                // Codex replays the user turn under its own id. Claude never
                // does. Either way the screen must show one bubble, not two.
                _ = await model.handle(
                    event(
                        7, "conversation.user_message",
                        .userMessage(
                            MessagePayload(
                                messageId: "server-user-1", role: .user, text: "ship it"
                            )
                        )
                    )
                )

                let users = await model.messages.filter { $0.role == .user }
                try expectEqual(users.count, 1, "the echo must not add a second bubble")
                try expectEqual(users[0].text, "ship it")
                try expectEqual(users[0].deliveryState, .sent)
            },

            TestCase("an unrelated user message is still shown") {
                let client = ControlledSendClient(mode: .history([]))
                let model = await makeViewModel(client: client)
                await model.send("ship it")

                _ = await model.handle(
                    event(
                        7, "conversation.user_message",
                        .userMessage(
                            MessagePayload(
                                messageId: "server-user-2", role: .user, text: "and deploy"
                            )
                        )
                    )
                )

                try expectEqual(
                    await model.messages.filter { $0.role == .user }.map(\.text),
                    ["ship it", "and deploy"]
                )
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

            TestCase("an earlier page is stored ahead of the newer one, without duplicates") {
                let duplicate = event(
                    2,
                    "conversation.message_completed",
                    .messageCompleted(
                        MessagePayload(messageId: "assistant-1", role: .assistant, text: "answer")
                    )
                )
                let first = HistoryPage(
                    events: [
                        event(
                            1,
                            "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-1", role: .user, text: "question")
                            )
                        ),
                        duplicate,
                    ],
                    hasMore: true,
                    nextCursor: "page-2"
                )
                let second = HistoryPage(
                    events: [
                        duplicate,
                        event(
                            3,
                            "conversation.reasoning_completed",
                            .reasoningCompleted(
                                ReasoningPayload(reasoningId: "reason-1", text: "checked")
                            )
                        ),
                    ],
                    hasMore: false,
                    nextCursor: nil
                )
                let client = ControlledSendClient(mode: .history([first, second]))
                let cache = InMemoryCatalogCache()
                let model = await makeViewModel(client: client, cache: cache)

                await model.loadHistory()
                await model.loadMoreHistory()

                try expectEqual(await model.messages.map(\.id), ["user-1", "assistant-1"])
                try expectEqual(await model.reasoning.map(\.id), ["reason-1"])
                try expectFalse(await model.hasMoreHistory)
                let stored = try expectNotNil(
                    cache.history(provider: .codex, conversationId: conversation.id)
                )
                // The second page is the earlier one, so what it added is
                // stored ahead of the first page, and the row both pages
                // carried is kept once.
                try expectEqual(stored.events.map(\.messageId), [
                    second.events[1].messageId,
                    first.events[0].messageId,
                    duplicate.messageId,
                ])
            },

            TestCase("an older history page is shown above the page already loaded") {
                // The transcript opens on the newest turns and pages
                // backwards, so the second page is *earlier* in time and its
                // rows belong above the first page's.
                let newest = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-2", role: .user, text: "later")
                            )
                        ),
                        event(
                            2, "conversation.message_completed",
                            .messageCompleted(
                                MessagePayload(
                                    messageId: "assistant-2", role: .assistant, text: "second"
                                )
                            )
                        ),
                    ],
                    hasMore: true,
                    nextCursor: "1"
                )
                let older = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-1", role: .user, text: "earlier")
                            )
                        ),
                        event(
                            2, "conversation.message_completed",
                            .messageCompleted(
                                MessagePayload(
                                    messageId: "assistant-1", role: .assistant, text: "first"
                                )
                            )
                        ),
                    ],
                    hasMore: false,
                    nextCursor: nil
                )
                let model = await makeViewModel(
                    client: ControlledSendClient(mode: .history([newest, older]))
                )

                await model.loadHistory()
                try expectEqual(await model.messages.map(\.id), ["user-2", "assistant-2"])

                await model.loadMoreHistory()

                try expectEqual(
                    await model.messages.map(\.id),
                    ["user-1", "assistant-1", "user-2", "assistant-2"],
                    "time still runs downwards; only the scroll position starts at the bottom"
                )
                try expectFalse(await model.hasMoreHistory)
            },

            TestCase("paging back leaves a turn in flight alone") {
                let newest = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-2", role: .user, text: "later")
                            )
                        )
                    ],
                    hasMore: true,
                    nextCursor: "1"
                )
                let older = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-1", role: .user, text: "earlier")
                            )
                        ),
                        event(
                            2, "turn.completed",
                            .turnCompleted(TurnPayload(turnId: "t-1"))
                        ),
                    ],
                    hasMore: false,
                    nextCursor: nil
                )
                let model = await makeViewModel(
                    client: ControlledSendClient(mode: .history([newest, older]))
                )
                await model.loadHistory()
                // A live turn is streaming while the user scrolls up.
                await model.handle(delta(9, "streaming", id: "live-1"))
                try expectTrue(await model.isRunning)

                await model.loadMoreHistory()

                try expectTrue(
                    await model.isRunning,
                    "an earlier page carries an old turn.completed; replaying it"
                        + " must not stop the turn that is running now"
                )
                try expectEqual(
                    await model.messages.map(\.id).last,
                    "live-1",
                    "the streaming reply stays at the bottom"
                )
            },

            TestCase("a live reply still appends after paging back") {
                let newest = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-2", role: .user, text: "later")
                            )
                        )
                    ],
                    hasMore: true,
                    nextCursor: "1"
                )
                let older = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "user-1", role: .user, text: "earlier")
                            )
                        )
                    ],
                    hasMore: false,
                    nextCursor: nil
                )
                let model = await makeViewModel(
                    client: ControlledSendClient(mode: .history([newest, older]))
                )
                await model.loadHistory()
                await model.loadMoreHistory()

                await model.handle(delta(9, "fresh", id: "live-1"))

                try expectEqual(
                    await model.messages.map(\.id),
                    ["user-1", "user-2", "live-1"],
                    "a new reply belongs at the bottom, below everything paged in"
                )
            },

            TestCase("a conversation immediately restores cached history before refresh") {
                let cache = InMemoryCatalogCache()
                let cached = event(
                    1,
                    "conversation.user_message",
                    .userMessage(
                        MessagePayload(messageId: "cached-user", role: .user, text: "cached")
                    )
                )
                cache.storeHistory(
                    HistorySnapshot(
                        provider: .codex,
                        conversationId: conversation.id,
                        events: [cached],
                        hasMore: true,
                        nextCursor: "cached-cursor"
                    )
                )

                let model = await makeViewModel(cache: cache)

                try expectEqual(await model.messages.map(\.id), ["cached-user"])
                try expectTrue(await model.hasMoreHistory)
            },

            TestCase("opening cached history explicitly refreshes its first page") {
                let cache = InMemoryCatalogCache()
                cache.storeHistory(
                    HistorySnapshot(
                        provider: .codex,
                        conversationId: conversation.id,
                        events: [],
                        hasMore: true,
                        nextCursor: "cached-next-page"
                    )
                )
                let client = ControlledSendClient(
                    mode: .history([
                        HistoryPage(events: [], hasMore: false, nextCursor: nil)
                    ])
                )
                let model = await makeViewModel(client: client, cache: cache)

                await model.loadHistory()

                try expectEqual(await client.historyCursors, [nil])
            },

            TestCase("opening and streaming a conversation issues no transfer request") {
                let client = MockAgentClient()
                let model = await makeViewModel(client: client)
                await model.loadHistory()
                await model.send("hello")

                try expectEqual(await client.transferRequestCount, 0)
            },
            TestCase("a conversation says it is loading while the page is in flight") {
                // The state the transcript shows a spinner for. Asserting it
                // after the load has finished would pass on a client that
                // never sets it at all.
                let client = ControlledSendClient(mode: .suspendedHistory)
                let model = await makeViewModel(client: client)

                let load = Task { await model.loadHistory() }
                var sawLoading = false
                for _ in 0..<50 where !sawLoading {
                    sawLoading = await model.isLoadingHistory
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                load.cancel()
                try expectTrue(
                    sawLoading,
                    "a read that has not answered yet must show as loading"
                )
                try expectFalse(
                    await model.hasLoadedHistoryOnce,
                    "nothing has landed, so the transcript is not settled"
                )
            },

            TestCase("a conversation reports that it is loading its first page") {
                // Opening a real conversation is not instant; without this the
                // screen is blank and indistinguishable from an empty one.
                let page = HistoryPage(
                    events: [
                        event(
                            1, "conversation.user_message",
                            .userMessage(
                                MessagePayload(messageId: "u1", role: .user, text: "hi")
                            )
                        )
                    ],
                    hasMore: false, nextCursor: nil
                )
                let client = ControlledSendClient(mode: .history([page]))
                let model = await makeViewModel(client: client)

                try expectFalse(await model.isLoadingHistory, "nothing has been asked for yet")
                await model.loadHistory()
                try expectFalse(
                    await model.isLoadingHistory, "the load finished, so the spinner stops"
                )
                try expectTrue(await model.hasLoadedHistoryOnce)
            },

            TestCase("a conversation has not finished loading until its first page lands") {
                // The flag the transcript uses to decide whether it may stop
                // following the newest end.
                let model = await makeViewModel()
                try expectFalse(
                    await model.hasLoadedHistoryOnce,
                    "an unopened conversation must not look settled"
                )
            },

        ]
    )
}

private actor ControlledSendClient: StubAgentClient {
    enum Mode: Sendable {
        case suspended
        case failure(AgentClientError)
        case history([HistoryPage])
        /// A history read that never answers, for observing the state a
        /// transcript is in while it waits.
        case suspendedHistory
    }

    nonisolated let events = AsyncStream<EventEnvelope> { continuation in
        continuation.finish()
    }

    private let mode: Mode
    private var sendStarted = false
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var historyIndex = 0
    private(set) var historyCursors: [String?] = []

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

    func send(
        provider: ProviderId, conversationId: String, text: String, attachments: [String]
    ) async throws {
        sendStarted = true
        switch mode {
        case .suspended:
            await withCheckedContinuation { sendContinuation = $0 }
        case let .failure(error):
            throw error
        case .history, .suspendedHistory:
            return
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
    ) async throws -> HistoryPage {
        if case .suspendedHistory = mode {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw AgentClientError.offline
        }
        guard case let .history(pages) = mode, historyIndex < pages.count else {
            throw AgentClientError.offline
        }
        historyCursors.append(cursor)
        defer { historyIndex += 1 }
        return pages[historyIndex]
    }
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

/// Records what a send actually carried. Nothing else here is scripted: the
/// point is the arguments, not the reply.
private actor RecordingSendClient: StubAgentClient {
    nonisolated let events = AsyncStream<EventEnvelope> { $0.finish() }

    private(set) var sentAttachments: [String] = []
    private(set) var sendCount = 0

    func send(
        provider: ProviderId, conversationId: String, text: String, attachments: [String]
    ) async throws {
        sendCount += 1
        sentAttachments = attachments
    }
}

/// Fails the first send the way a dropped connection would, then records the
/// retry.
private actor FailThenRecordClient: StubAgentClient {
    nonisolated let events = AsyncStream<EventEnvelope> { $0.finish() }

    private(set) var sentAttachments: [String] = []
    private var refusedOnce = false

    func send(
        provider: ProviderId, conversationId: String, text: String, attachments: [String]
    ) async throws {
        guard refusedOnce else {
            refusedOnce = true
            throw AgentClientError.transport("dropped")
        }
        sentAttachments = attachments
    }
}
