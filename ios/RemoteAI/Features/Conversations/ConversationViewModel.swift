import Foundation
import Observation

public struct MessageItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let role: MessageRole
    public internal(set) var text: String
    public internal(set) var isStreaming: Bool
}

public struct ToolItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public internal(set) var detail: String?
    public internal(set) var status: String?
}

public struct ErrorItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let code: String
    public let message: String
}

/// One row of the conversation transcript.
public enum TimelineItem: Identifiable, Sendable, Hashable {
    case message(MessageItem)
    case tool(ToolItem)
    case approval(ApprovalRequest)
    case error(ErrorItem)

    public var id: String {
        switch self {
        case let .message(item): return "message:\(item.id)"
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
    private var sequencer = EventSequencer()
    private var historyCursor: String?
    /// Deltas from the Rust agent carry no message id, so one turn's fragments
    /// are coalesced under a synthetic id that is cleared when the turn ends.
    private var currentStreamId: String?

    public init(conversation: ConversationSummary, client: AgentClient) {
        self.conversation = conversation
        self.client = client
    }

    // MARK: - Derived views of the timeline

    public var messages: [MessageItem] {
        items.compactMap { if case let .message(item) = $0 { return item } else { return nil } }
    }

    public var tools: [ToolItem] {
        items.compactMap { if case let .tool(item) = $0 { return item } else { return nil } }
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
        do {
            let page = try await client.history(
                provider: conversation.provider,
                conversationId: conversation.id,
                cursor: historyCursor,
                limit: limit
            )
            hasMoreHistory = page.hasMore
            historyCursor = page.nextCursor
            for envelope in page.events {
                apply(envelope.event)
                _ = sequencer.accept(envelope)
            }
        } catch {
            appendError(code: "history_failed", message: "\(error)")
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isOnline else {
            failedDraft = trimmed
            appendError(code: "offline", message: "Mac is offline. The message was not sent.")
            return
        }
        do {
            try await client.send(
                provider: conversation.provider, conversationId: conversation.id, text: trimmed
            )
            failedDraft = nil
        } catch {
            failedDraft = trimmed
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
        case .rejected: return "The Mac rejected this message."
        case .transport: return "The message could not reach the Mac."
        default: return "The message could not be sent."
        }
    }

    /// Only ever called from the retry button; nothing retries on its own.
    public func retryFailedSend() async {
        guard let draft = failedDraft else { return }
        failedDraft = nil
        await send(draft)
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
            upsertMessage(payload, streaming: false)
            isRunning = true

        case let .delta(payload):
            appendDelta(payload)
            isRunning = true

        case let .messageCompleted(payload):
            upsertMessage(payload, streaming: false, replaceText: true)

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

    private func appendDelta(_ payload: MessagePayload) {
        let messageId = payload.messageId ?? currentStreamId ?? "stream-\(items.count)"
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
        _ payload: MessagePayload, streaming: Bool, replaceText: Bool = false
    ) {
        let messageId =
            payload.messageId
            ?? (payload.role == .user ? "user-\(items.count)" : currentStreamId)
            ?? "message-\(items.count)"

        if let index = indexOfMessage(messageId) {
            guard case var .message(item) = items[index] else { return }
            if replaceText { item.text = payload.text }
            item.isStreaming = streaming
            items[index] = .message(item)
        } else {
            items.append(
                .message(
                    MessageItem(
                        id: messageId, role: payload.role,
                        text: payload.text, isStreaming: streaming
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

    private func indexOfMessage(_ id: String) -> Int? {
        items.firstIndex { $0.id == "message:\(id)" }
    }

    private func finishStreaming() {
        // The next turn's unlabelled deltas must start a new message.
        currentStreamId = nil
        for index in items.indices {
            guard case var .message(item) = items[index], item.isStreaming else { continue }
            item.isStreaming = false
            items[index] = .message(item)
        }
    }

    private func appendError(code: String, message: String) {
        items.append(
            .error(ErrorItem(id: "\(code)-\(items.count)", code: code, message: message))
        )
    }
}
