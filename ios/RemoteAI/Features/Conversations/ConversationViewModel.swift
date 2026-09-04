import Foundation
import Observation

public enum MessageDeliveryState: String, Sendable, Hashable {
    case sending
    case sent
    case failed
}

public struct MessageItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let role: MessageRole
    public internal(set) var text: String
    public internal(set) var isStreaming: Bool
    public internal(set) var deliveryState: MessageDeliveryState?

    public init(
        id: String,
        role: MessageRole,
        text: String,
        isStreaming: Bool,
        deliveryState: MessageDeliveryState? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.deliveryState = deliveryState
    }
}

public struct ToolItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public internal(set) var detail: String?
    public internal(set) var status: String?
}

public struct ReasoningItem: Identifiable, Sendable, Hashable {
    public let id: String
    public internal(set) var text: String
    public internal(set) var isStreaming: Bool
    public var isExpanded: Bool

    public init(
        id: String,
        text: String,
        isStreaming: Bool,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.text = text
        self.isStreaming = isStreaming
        self.isExpanded = isExpanded
    }
}

public struct ErrorItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let code: String
    public let message: String
}

/// One row of the conversation transcript.
public enum TimelineItem: Identifiable, Sendable, Hashable {
    case message(MessageItem)
    case reasoning(ReasoningItem)
    case tool(ToolItem)
    case approval(ApprovalRequest)
    case error(ErrorItem)

    public var id: String {
        switch self {
        case let .message(item): return "message:\(item.id)"
        case let .reasoning(item): return "reasoning:\(item.id)"
        case let .tool(item): return "tool:\(item.id)"
        case let .approval(request): return "approval:\(request.id)"
        case let .error(item): return "error:\(item.id)"
        }
    }
}

/// Drives one conversation screen: streaming transcript, tool activity,
/// approval cards, stop and retry.
@MainActor
@Observable
public final class ConversationViewModel {
    public let conversation: ConversationSummary
    public private(set) var items: [TimelineItem] = []
    public private(set) var pendingApproval: ApprovalRequest?
    public private(set) var isRunning = false
    public private(set) var failedDraft: String?
    public private(set) var hasMoreHistory = false

    /// Mirrors `AppModel.isOnline`; offline is read-only.
    public var isOnline = true

    private let client: AgentClient
    private let cache: CatalogCache?
    private var sequencer = EventSequencer()
    private var historyCursor: String?
    private var historyEvents: [EventEnvelope] = []
    private var historyEventIds: Set<String> = []
    /// Deltas from the Rust agent carry no message id, so one turn's fragments
    /// are coalesced under a synthetic id that is cleared when the turn ends.
    private var currentStreamId: String?
    private var failedMessageId: String?
    /// Provider echoes of the local user turn that have already been folded in.
    private var reconciledUserEchoes: Set<String> = []
    /// Distinguishes rows the provider gave no id of its own. It counts rather
    /// than reading `items.count`, which restarts while an earlier page is
    /// replayed into a timeline of its own.
    private var syntheticRowCount = 0

    /// Prefix of an optimistic user message, which exists before any provider
    /// has given the turn an id.
    private static let localMessagePrefix = "local-"

    public init(
        conversation: ConversationSummary,
        client: AgentClient,
        cache: CatalogCache? = nil
    ) {
        self.conversation = conversation
        self.client = client
        self.cache = cache
        if let cached = cache?.history(
            provider: conversation.provider,
            conversationId: conversation.id
        ) {
            mergeHistory(cached.events, isEarlierThanWhatIsShown: false)
            hasMoreHistory = cached.hasMore
            historyCursor = cached.nextCursor
        }
    }

    // MARK: - Derived views of the timeline

    public var messages: [MessageItem] {
        items.compactMap { if case let .message(item) = $0 { return item } else { return nil } }
    }

    public var tools: [ToolItem] {
        items.compactMap { if case let .tool(item) = $0 { return item } else { return nil } }
    }

    public var reasoning: [ReasoningItem] {
        items.compactMap { if case let .reasoning(item) = $0 { return item } else { return nil } }
    }

    public var errors: [ErrorItem] {
        items.compactMap { if case let .error(item) = $0 { return item } else { return nil } }
    }

    /// v1 offers exactly these two. There is no permanent allow.
    public var availableDecisions: [ApprovalDecision] { [.allowOnce, .deny] }

    public var canStop: Bool { isRunning }
    public var canRetry: Bool { failedDraft != nil }

    // MARK: - Commands

    public func loadHistory(limit: Int = 100) async {
        await fetchHistory(cursor: nil, limit: limit)
    }

    public func loadMoreHistory(limit: Int = 100) async {
        guard hasMoreHistory, let historyCursor else { return }
        await fetchHistory(cursor: historyCursor, limit: limit)
    }

    public func refreshHistory(limit: Int = 100) async {
        await fetchHistory(cursor: nil, limit: limit)
    }

    private func fetchHistory(cursor: String?, limit: Int) async {
        do {
            let page = try await client.history(
                provider: conversation.provider,
                conversationId: conversation.id,
                cursor: cursor,
                limit: limit
            )
            hasMoreHistory = page.hasMore
            historyCursor = page.nextCursor
            // Only a cursored read walks backwards. The first page of a screen
            // — and a refresh — is the newest end of the transcript.
            mergeHistory(page.events, isEarlierThanWhatIsShown: cursor != nil)
            cache?.storeHistory(
                HistorySnapshot(
                    provider: conversation.provider,
                    conversationId: conversation.id,
                    events: historyEvents,
                    hasMore: hasMoreHistory,
                    nextCursor: historyCursor
                )
            )
        } catch {
            appendError(code: "history_failed", message: "\(error)")
        }
    }

    /// Fold one history page into the transcript.
    ///
    /// Time runs downwards on screen, so a page read with a cursor — which is
    /// earlier than everything already shown — is replayed into a timeline of
    /// its own and that timeline goes above the rest. Replaying it in place
    /// would append its rows to the bottom and reorder the conversation.
    ///
    /// The replay must not disturb what is happening *now*: an earlier page
    /// ends in its own `turn.completed`, and applying that would stop a turn
    /// that is still running. Live state is therefore restored afterwards.
    private func mergeHistory(_ events: [EventEnvelope], isEarlierThanWhatIsShown: Bool) {
        let fresh = events.filter { envelope in
            envelope.conversationId == conversation.id
                && historyEventIds.insert(envelope.messageId).inserted
        }
        guard !fresh.isEmpty else { return }

        guard isEarlierThanWhatIsShown else {
            historyEvents.append(contentsOf: fresh)
            for envelope in fresh { apply(envelope.event) }
            return
        }

        historyEvents.insert(contentsOf: fresh, at: 0)
        let shown = items
        let running = isRunning
        let approval = pendingApproval
        let streamId = currentStreamId
        items = []
        currentStreamId = nil
        for envelope in fresh { apply(envelope.event) }
        items += shown
        isRunning = running
        pendingApproval = approval
        currentStreamId = streamId
    }

    private func nextSyntheticId() -> Int {
        syntheticRowCount += 1
        return syntheticRowCount
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let messageId = "\(Self.localMessagePrefix)\(UUID().uuidString)"
        items.append(
            .message(
                MessageItem(
                    id: messageId,
                    role: .user,
                    text: trimmed,
                    isStreaming: false,
                    deliveryState: .sending
                )
            )
        )
        await send(messageId: messageId, text: trimmed)
    }

    private func send(messageId: String, text: String) async {
        guard isOnline else {
            markDelivery(messageId, as: .failed)
            failedMessageId = messageId
            failedDraft = text
            appendError(code: "offline", message: "Mac is offline. The message was not sent.")
            return
        }
        do {
            try await client.send(
                provider: conversation.provider, conversationId: conversation.id, text: text
            )
            markDelivery(messageId, as: .sent)
            failedMessageId = nil
            failedDraft = nil
        } catch {
            markDelivery(messageId, as: .failed)
            failedMessageId = messageId
            failedDraft = text
            appendError(code: Self.errorCode(for: error), message: Self.errorMessage(for: error))
        }
    }

    private static func errorCode(for error: Error) -> String {
        if case let AgentClientError.rejected(code) = error { return code }
        if case AgentClientError.offline = error { return "offline" }
        if case AgentClientError.notPaired = error { return "not_paired" }
        return "send_failed"
    }

    private static func errorMessage(for error: Error) -> String {
        switch error as? AgentClientError {
        case .offline: return "Mac is offline. The message was not sent."
        case .notPaired: return "Pair with your Mac before sending a message."
        case .rejected("session_busy"):
            return "This conversation is active elsewhere. You can view its history, but cannot send."
        case .rejected: return "The Mac rejected this message."
        case .transport: return "The message could not reach the Mac."
        default: return "The message could not be sent."
        }
    }

    /// Only ever called from the retry button; nothing retries on its own.
    public func retryFailedSend() async {
        guard let draft = failedDraft, let messageId = failedMessageId else { return }
        markDelivery(messageId, as: .sending)
        await send(messageId: messageId, text: draft)
    }

    public func stop() async {
        guard isRunning else { return }
        guard isOnline else {
            appendError(code: "offline", message: "Mac is offline. The task was not stopped.")
            return
        }
        do {
            try await client.interrupt(
                provider: conversation.provider, conversationId: conversation.id
            )
        } catch {
            appendError(code: "interrupt_failed", message: "\(error)")
        }
    }

    public func decide(_ decision: ApprovalDecision) async {
        guard let approval = pendingApproval else { return }
        guard isOnline else {
            appendError(code: "offline", message: "Mac is offline. No decision was sent.")
            return
        }
        do {
            try await client.decideApproval(id: approval.id, decision: decision)
        } catch {
            appendError(code: "approval_failed", message: "\(error)")
        }
    }

    // MARK: - Events

    /// The realtime feed this screen consumes.
    public func eventStream() async -> AsyncStream<EventEnvelope> {
        await client.events
    }

    @discardableResult
    public func handle(_ envelope: EventEnvelope) -> Bool {
        guard envelope.conversationId == conversation.id else { return false }
        guard sequencer.accept(envelope) else { return false }
        apply(envelope.event)
        return true
    }

    private func apply(_ event: ConversationEvent) {
        switch event {
        case let .userMessage(payload):
            if !reconcileUserEcho(payload) {
                upsertMessage(payload, streaming: false, deliveryState: .sent)
            }
            isRunning = true

        case let .delta(payload):
            appendDelta(payload)
            isRunning = true

        case let .messageCompleted(payload):
            upsertMessage(payload, streaming: false, replaceText: true)

        case let .reasoningDelta(payload):
            upsertReasoning(payload, streaming: true, replaceText: false)

        case let .reasoningCompleted(payload):
            upsertReasoning(payload, streaming: false, replaceText: true)

        case let .toolStarted(payload), let .toolUpdated(payload), let .toolCompleted(payload):
            upsertTool(payload)

        case let .approvalRequested(request):
            pendingApproval = request
            if !items.contains(where: { $0.id == "approval:\(request.id)" }) {
                items.append(.approval(request))
            }

        case let .approvalResolved(resolution):
            if pendingApproval?.id == resolution.id { pendingApproval = nil }

        case .turnCompleted, .turnInterrupted:
            isRunning = false
            finishStreaming()

        case let .turnFailed(failure):
            isRunning = false
            finishStreaming()
            appendError(code: failure.code, message: failure.message)

        case .started, .providerStatusChanged, .unsupported:
            // Nothing to show in this transcript.
            break
        }
    }

    // MARK: - Timeline mutation

    /// Claude never echoes the user's own turn; Codex replays it under a
    /// provider id. When an echo does arrive, fold it into the optimistic
    /// bubble instead of showing the same text twice.
    private func reconcileUserEcho(_ payload: MessagePayload) -> Bool {
        guard payload.role == .user, let messageId = payload.messageId,
            !reconciledUserEchoes.contains(messageId)
        else { return false }

        let match = items.lastIndex { item in
            guard case let .message(message) = item else { return false }
            return message.role == .user
                && message.deliveryState != nil
                && message.id.hasPrefix(Self.localMessagePrefix)
                && message.text == payload.text
        }
        guard let match, case var .message(local) = items[match] else { return false }

        local.deliveryState = .sent
        items[match] = .message(local)
        reconciledUserEchoes.insert(messageId)
        return true
    }

    private func appendDelta(_ payload: MessagePayload) {
        let messageId = payload.messageId ?? currentStreamId ?? "stream-\(nextSyntheticId())"
        currentStreamId = messageId

        if let index = indexOfMessage(messageId) {
            guard case var .message(item) = items[index] else { return }
            item.text += payload.text
            item.isStreaming = true
            items[index] = .message(item)
        } else {
            items.append(
                .message(
                    MessageItem(
                        id: messageId, role: payload.role,
                        text: payload.text, isStreaming: true
                    )
                )
            )
        }
    }

    private func upsertMessage(
        _ payload: MessagePayload,
        streaming: Bool,
        replaceText: Bool = false,
        deliveryState: MessageDeliveryState? = nil
    ) {
        let messageId =
            payload.messageId
            ?? (payload.role == .user ? "user-\(nextSyntheticId())" : currentStreamId)
            ?? "message-\(nextSyntheticId())"

        if let index = indexOfMessage(messageId) {
            guard case var .message(item) = items[index] else { return }
            if replaceText { item.text = payload.text }
            item.isStreaming = streaming
            item.deliveryState = deliveryState ?? item.deliveryState
            items[index] = .message(item)
        } else {
            items.append(
                .message(
                    MessageItem(
                        id: messageId, role: payload.role,
                        text: payload.text, isStreaming: streaming,
                        deliveryState: deliveryState
                    )
                )
            )
        }
    }

    private func upsertTool(_ payload: ToolPayload) {
        if let index = items.firstIndex(where: { $0.id == "tool:\(payload.toolCallId)" }) {
            guard case var .tool(item) = items[index] else { return }
            item.detail = payload.detail ?? item.detail
            item.status = payload.status ?? item.status
            items[index] = .tool(item)
        } else {
            items.append(
                .tool(
                    ToolItem(
                        id: payload.toolCallId, name: payload.name,
                        detail: payload.detail, status: payload.status
                    )
                )
            )
        }
    }

    private func upsertReasoning(
        _ payload: ReasoningPayload,
        streaming: Bool,
        replaceText: Bool
    ) {
        if let index = items.firstIndex(where: { $0.id == "reasoning:\(payload.reasoningId)" }) {
            guard case var .reasoning(item) = items[index] else { return }
            item.text = replaceText ? payload.text : item.text + payload.text
            item.isStreaming = streaming
            items[index] = .reasoning(item)
        } else {
            items.append(
                .reasoning(
                    ReasoningItem(
                        id: payload.reasoningId,
                        text: payload.text,
                        isStreaming: streaming
                    )
                )
            )
        }
    }

    private func indexOfMessage(_ id: String) -> Int? {
        items.firstIndex { $0.id == "message:\(id)" }
    }

    private func markDelivery(_ id: String, as state: MessageDeliveryState) {
        guard let index = indexOfMessage(id), case var .message(item) = items[index] else { return }
        item.deliveryState = state
        items[index] = .message(item)
    }

    private func finishStreaming() {
        // The next turn's unlabelled deltas must start a new message.
        currentStreamId = nil
        for index in items.indices {
            switch items[index] {
            case var .message(item) where item.isStreaming:
                item.isStreaming = false
                items[index] = .message(item)
            case var .reasoning(item) where item.isStreaming:
                item.isStreaming = false
                items[index] = .reasoning(item)
            default:
                continue
            }
        }
    }

    private func appendError(code: String, message: String) {
        items.append(
            .error(ErrorItem(id: "\(code)-\(nextSyntheticId())", code: code, message: message))
        )
    }
}
