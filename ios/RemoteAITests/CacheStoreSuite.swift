import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum CacheStoreSuite {
    static func event(_ id: String, sequence: Int = 1) -> EventEnvelope {
        EventEnvelope(
            messageId: id,
            sequence: sequence,
            conversationId: "session-a",
            rawType: "conversation.user_message",
            event: .userMessage(
                MessagePayload(messageId: "user-1", role: .user, text: "cached")
            )
        )
    }

    public static let suite = TestSuite(
        name: "CacheStoreSuite",
        cases: [
            TestCase("file cache persists normalized history by provider and conversation") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let first = FileCatalogCache(directory: directory)
                first.storeHistory(
                    HistorySnapshot(
                        provider: .claude,
                        conversationId: "session-a",
                        events: [event("history-1")],
                        hasMore: true,
                        nextCursor: "cursor-a"
                    )
                )

                let second = FileCatalogCache(directory: directory)
                let restored = try expectNotNil(
                    second.history(provider: .claude, conversationId: "session-a")
                )
                try expectEqual(restored.events, [event("history-1")])
                try expectTrue(restored.hasMore)
                try expectEqual(restored.nextCursor, "cursor-a")
                try expectNil(
                    second.history(provider: .codex, conversationId: "session-a"),
                    "the same session id under another provider must use a different cache key"
                )
            },
        ]
    )
}
