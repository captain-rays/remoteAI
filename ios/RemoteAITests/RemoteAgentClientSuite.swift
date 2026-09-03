import CryptoKit
import Foundation
import RemoteAIKit
import RemoteAITestKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RemoteAgentClientSuite {
    static func makeClient() throws -> RemoteAgentClient {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let macKey = P256.KeyAgreement.PrivateKey()
        let store = InMemorySecretStore()
        try store.save(
            DeviceIdentity(
                macId: "mac-test",
                origin: "https://agent.example",
                privateKey: phoneKey.rawRepresentation,
                macPublicKey: macKey.publicKey.x963Representation
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return RemoteAgentClient(store: store, session: URLSession(configuration: configuration))
    }

    public static let suite = TestSuite(
        name: "RemoteAgentClientSuite",
        cases: [
            TestCase("real catalog requests remain provider scoped") {
                let client = try makeClient()

                let daily = try await client.listDailyConversations(provider: .claude)
                let projects = try await client.listProjects(provider: .codex)
                let sessions = try await client.listProjectConversations(
                    provider: .codex,
                    projectId: "codex:/Users/dev/work/api"
                )

                try expectEqual(daily.map(\.provider), [.claude])
                try expectEqual(projects.map(\.provider), [.codex])
                try expectEqual(sessions.map(\.provider), [.codex])
                try expectEqual(sessions.first?.projectId, "codex:/Users/dev/work/api")
            },

            TestCase("Rust compact history pages decode into stable event envelopes") {
                let json = """
                {
                  "conversationId": "session-a",
                  "events": [
                    {
                      "type": "conversation.user_message",
                      "payload": {"messageId":"user-1","role":"user","text":"hello"}
                    },
                    {
                      "type": "conversation.reasoning_completed",
                      "payload": {"reasoningId":"reason-1","text":"checked"}
                    }
                  ],
                  "nextCursor": "2"
                }
                """

                let first = try RemoteAgentClient.decodeHistoryPage(
                    Data(json.utf8), provider: .claude, conversationId: "session-a"
                )
                let second = try RemoteAgentClient.decodeHistoryPage(
                    Data(json.utf8), provider: .claude, conversationId: "session-a"
                )

                try expectEqual(first.events.map(\.messageId), second.events.map(\.messageId))
                try expectEqual(first.events.count, 2)
                try expectTrue(first.hasMore)
                try expectEqual(first.nextCursor, "2")
                guard case let .userMessage(user) = first.events[0].event else {
                    throw ExpectationFailure(
                        message: "expected user message", file: #filePath, line: #line
                    )
                }
                try expectEqual(user.messageId, "user-1")
                guard case let .reasoningCompleted(reasoning) = first.events[1].event else {
                    throw ExpectationFailure(
                        message: "expected reasoning", file: #filePath, line: #line
                    )
                }
                try expectEqual(reasoning.reasoningId, "reason-1")
            },

            TestCase("Rust compact tool history accepts toolId and a missing completion name") {
                let json = """
                {
                  "conversationId": "session-a",
                  "events": [
                    {
                      "type": "tool.started",
                      "payload": {"toolId":"tool-1","name":"Bash"}
                    },
                    {
                      "type": "tool.completed",
                      "payload": {"toolId":"tool-1","text":"finished"}
                    }
                  ],
                  "nextCursor": null
                }
                """

                let page = try RemoteAgentClient.decodeHistoryPage(
                    Data(json.utf8), provider: .claude, conversationId: "session-a"
                )

                guard case let .toolStarted(started) = page.events[0].event else {
                    throw ExpectationFailure(
                        message: "expected tool.started", file: #filePath, line: #line
                    )
                }
                guard case let .toolCompleted(completed) = page.events[1].event else {
                    throw ExpectationFailure(
                        message: "expected tool.completed", file: #filePath, line: #line
                    )
                }
                try expectEqual(started.toolCallId, "tool-1")
                try expectEqual(completed.toolCallId, "tool-1")
                try expectEqual(completed.detail, "finished")
            },
        ]
    )
}

private final class CatalogURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "x-remoteai-device")?.isEmpty == false
        else {
            finish(status: 401, body: "{}")
            return
        }

        let absolute = url.absoluteString
        if url.path == "/v1/conversations/daily",
           url.query == "provider=claude"
        {
            finish(
                body: #"[{"id":"claude-daily","provider":"claude","kind":"daily","title":"Daily","updatedAt":"2026-09-03T00:00:00Z","status":"idle"}]"#
            )
        } else if url.path == "/v1/projects", url.query == "provider=codex" {
            finish(
                body: #"[{"id":"codex:/Users/dev/work/api","provider":"codex","canonicalPath":"/Users/dev/work/api","displayPath":"~/work/api","title":"api","updatedAt":"2026-09-03T00:00:00Z","available":true}]"#
            )
        } else if absolute.contains(
            "/v1/projects/codex:%2FUsers%2Fdev%2Fwork%2Fapi/conversations?provider=codex"
        ) {
            finish(
                body: #"[{"id":"codex-project","provider":"codex","kind":"project","title":"Project","projectId":"codex:/Users/dev/work/api","projectPath":"/Users/dev/work/api","updatedAt":"2026-09-03T00:00:00Z","status":"idle"}]"#
            )
        } else {
            finish(status: 404, body: "{}")
        }
    }

    private func finish(status: Int = 200, body: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
