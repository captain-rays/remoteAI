import Foundation
import RemoteAIKit
import RemoteAITestKit

/// Decoding contract against the payload shapes the Rust agent really emits.
///
/// These are captured verbatim from a live `remote-ai-agent` talking to
/// `claude 2.1.210`, not invented by the client. The original client models
/// were written against client-authored fixtures, so every one of these events
/// decoded to `.unsupported` and the app silently dropped Claude's replies.
public enum AgentContractSuite {

    static func eventData(_ type: String, _ payload: String, sequence: Int = 1) -> Data {
        Data(
            """
            {
              "protocolVersion": 1,
              "messageId": "evt-\(sequence)",
              "kind": "event",
              "requestId": null,
              "sequence": \(sequence),
              "conversationId": "pending-3e0816b6",
              "type": "\(type)",
              "payload": \(payload)
            }
            """.utf8
        )
    }

    public static let suite = TestSuite(
        name: "AgentContractSuite",
        cases: [
            TestCase("a delta carrying only text decodes as a delta, not unsupported") {
                // agent: ConversationEvent::Delta { text } -> {"text": ...}
                let envelope = try ProtocolCoding.decodeEvent(
                    from: eventData("conversation.delta", #"{"text":"O"}"#)
                )
                guard case let .delta(delta) = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .delta, got \(envelope.event)",
                        file: #filePath, line: #line
                    )
                }
                try expectEqual(delta.text, "O")
                try expectEqual(delta.role, .assistant, "an unlabelled delta is the assistant")
            },

            TestCase("turn.completed carrying the CLI result object is recognised") {
                // agent: ConversationEvent::TurnCompleted(<claude result object>)
                let payload = """
                {"type":"result","subtype":"success","is_error":false,
                 "duration_ms":4269,"num_turns":1,"result":"OK",
                 "session_id":"324cf80c-d497-4d56-ab40-57ab52866caa"}
                """
                let envelope = try ProtocolCoding.decodeEvent(
                    from: eventData("turn.completed", payload)
                )
                guard case .turnCompleted = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .turnCompleted, got \(envelope.event)",
                        file: #filePath, line: #line
                    )
                }
            },

            TestCase("a turn.failed with no wording at all still names the failure") {
                // Verbatim shape from claude 2.1.210 when `--resume` cannot
                // find the session: a result with a subtype and nothing else.
                let payload = """
                    {"type":"result","subtype":"error_during_execution","is_error":true}
                    """
                let envelope = try ProtocolCoding.decodeEvent(
                    from: eventData("turn.failed", payload)
                )
                guard case let .turnFailed(failure) = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .turnFailed, got \(envelope.event)",
                        file: #filePath, line: #line
                    )
                }
                try expectEqual(failure.code, "error_during_execution")
                try expectFalse(
                    failure.message.isEmpty,
                    "an empty row tells the user nothing; name the failure"
                )
            },

            TestCase("turn.failed carrying the CLI error result is recognised") {
                let payload = """
                {"type":"result","subtype":"success","is_error":true,
                 "api_error_status":429,
                 "result":"Fable 5 requires usage credits. /model to switch models.",
                 "session_id":"e86e4464"}
                """
                let envelope = try ProtocolCoding.decodeEvent(
                    from: eventData("turn.failed", payload)
                )
                guard case let .turnFailed(failure) = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .turnFailed, got \(envelope.event)",
                        file: #filePath, line: #line
                    )
                }
                try expectTrue(
                    failure.message.contains("usage credits"),
                    "the user must be told why the turn failed, got \(failure.message)"
                )
            },

            TestCase("conversation.started from the agent is recognised") {
                // agent: {"provider","sessionId","cwd","model"}
                let payload = """
                {"provider":"claude","sessionId":"324cf80c-d497-4d56-ab40-57ab52866caa",
                 "cwd":"/Users/dev/work/api","model":"claude-sonnet-5"}
                """
                let envelope = try ProtocolCoding.decodeEvent(
                    from: eventData("conversation.started", payload)
                )
                guard case let .started(started) = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .started, got \(envelope.event)",
                        file: #filePath, line: #line
                    )
                }
                try expectEqual(
                    started.sessionId, "324cf80c-d497-4d56-ab40-57ab52866caa",
                    "the provider-native session id must survive"
                )
            },

            TestCase("a genuinely unknown event still degrades safely") {
                let envelope = try ProtocolCoding.decodeEvent(
                    from: eventData("conversation.telepathy", #"{"anything":1}"#)
                )
                try expectEqual(
                    envelope.event, .unsupported(rawType: "conversation.telepathy")
                )
            },

            TestCase("streamed deltas without ids build one assistant message") {
                let conversation = ConversationSummary(
                    id: "pending-3e0816b6", provider: .claude, kind: .daily,
                    title: "New Claude session",
                    updatedAt: Date(timeIntervalSince1970: 1_788_000_000), status: .idle
                )
                let model = await ConversationViewModel(
                    conversation: conversation, client: MockAgentClient()
                )
                for (index, fragment) in ["O", "K", "!"].enumerated() {
                    await model.handle(
                        try ProtocolCoding.decodeEvent(
                            from: eventData(
                                "conversation.delta", "{\"text\":\"\(fragment)\"}",
                                sequence: index + 1
                            )
                        )
                    )
                }
                let messages = await model.messages
                try expectEqual(messages.count, 1, "one reply, not three")
                try expectEqual(messages[0].text, "OK!")
                try expectTrue(await model.canStop, "the turn is still running")
            },

            TestCase("a second turn starts a new message instead of appending") {
                let conversation = ConversationSummary(
                    id: "pending-3e0816b6", provider: .claude, kind: .daily,
                    title: "New Claude session",
                    updatedAt: Date(timeIntervalSince1970: 1_788_000_000), status: .idle
                )
                let model = await ConversationViewModel(
                    conversation: conversation, client: MockAgentClient()
                )
                await model.handle(
                    try ProtocolCoding.decodeEvent(
                        from: eventData("conversation.delta", #"{"text":"first"}"#, sequence: 1)
                    )
                )
                await model.handle(
                    try ProtocolCoding.decodeEvent(
                        from: eventData(
                            "turn.completed", #"{"type":"result","result":"first"}"#, sequence: 2
                        )
                    )
                )
                try expectFalse(await model.canStop, "the turn ended")

                await model.handle(
                    try ProtocolCoding.decodeEvent(
                        from: eventData("conversation.delta", #"{"text":"second"}"#, sequence: 3)
                    )
                )
                let messages = await model.messages
                try expectEqual(messages.count, 2, "a new turn is a new message")
                try expectEqual(messages[0].text, "first")
                try expectEqual(messages[1].text, "second")
            },
        ]
    )
}
