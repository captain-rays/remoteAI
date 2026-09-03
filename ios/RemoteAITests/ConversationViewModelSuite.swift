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
        client: MockAgentClient = MockAgentClient(),
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
