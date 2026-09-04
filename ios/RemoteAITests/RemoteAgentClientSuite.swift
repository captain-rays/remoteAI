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

            TestCase("real file browsing derives the home and decodes absolute entries") {
                let client = try makeClient()

                let home = try await client.initialDirectory()
                let work = try await client.listFiles(
                    path: "/Users/dev/work", showHidden: false
                )

                try expectEqual(home.path, "/Users/dev")
                try expectEqual(home.parentPath, nil, "the configured file root has no parent")
                try expectEqual(home.entries.map(\.name), ["work", "README.md"])
                try expectEqual(work.path, "/Users/dev/work")
                try expectEqual(work.parentPath, "/Users/dev")
                try expectEqual(work.entries.map(\.path), ["/Users/dev/work/api"])
            },

            TestCase("real preview combines metadata with raw bounded bytes") {
                let client = try makeClient()

                let preview = try await client.filePreview(
                    path: "/Users/dev/README.md", maxBytes: 5
                )

                try expectEqual(preview.path, "/Users/dev/README.md")
                try expectEqual(preview.text, "hello")
                try expectEqual(preview.byteCount, 12)
                try expectTrue(preview.truncated)
            },

            TestCase("file path rejection is surfaced as a stable client error") {
                let client = try makeClient()

                do {
                    _ = try await client.listFiles(path: "/outside", showHidden: false)
                    throw ExpectationFailure(
                        message: "outside path should be rejected", file: #filePath, line: #line
                    )
                } catch let error as AgentClientError {
                    try expectEqual(error, .rejected("path_outside_root"))
                }
            },

            TestCase("upload REST maps chunk indexes to byte offsets and finishes") {
                let client = try makeClient()
                let request = TransferRequest(
                    direction: .upload,
                    name: "new.bin",
                    remoteDirectory: "/Users/dev/work",
                    byteCount: 1_048_577,
                    conflictPolicy: nil,
                    expectedSha256: "digest-123"
                )

                let ticket = try await client.createTransfer(request)
                try await client.uploadChunk(
                    transferId: ticket.id, index: 1, data: Data("z".utf8)
                )
                let receipt = try await client.finishTransfer(transferId: ticket.id)

                try expectEqual(ticket.id, "upload-1")
                try expectEqual(ticket.destinationPath, "/Users/dev/work/new.bin")
                try expectEqual(ticket.chunkSize, 1_048_576)
                try expectEqual(ticket.totalChunks, 2)
                try expectNil(ticket.conflict)
                try expectEqual(receipt.finalPath, ticket.destinationPath)
                try expectEqual(receipt.sha256, "digest-123")
            },

            TestCase("upload conflict returns a decision ticket instead of throwing") {
                let client = try makeClient()
                let request = TransferRequest(
                    direction: .upload,
                    name: "existing.txt",
                    remoteDirectory: "/Users/dev/work",
                    byteCount: 7,
                    conflictPolicy: nil,
                    expectedSha256: "digest-conflict"
                )

                let ticket = try await client.createTransfer(request)

                try expectEqual(ticket.destinationPath, "/Users/dev/work/existing.txt")
                try expectEqual(ticket.conflict?.existingPath, "/Users/dev/work/existing.txt")
                try expectEqual(ticket.conflict?.existingSize, 42)
            },

            TestCase("cancelling an upload removes its remote and local transfer state") {
                let client = try makeClient()
                let ticket = try await client.createTransfer(
                    TransferRequest(
                        direction: .upload,
                        name: "new.bin",
                        remoteDirectory: "/Users/dev/work",
                        byteCount: 1,
                        conflictPolicy: nil,
                        expectedSha256: "digest-123"
                    )
                )

                try await client.cancelTransfer(transferId: ticket.id)

                do {
                    try await client.uploadChunk(
                        transferId: ticket.id, index: 0, data: Data("x".utf8)
                    )
                    throw ExpectationFailure(
                        message: "cancelled upload should not accept chunks",
                        file: #filePath,
                        line: #line
                    )
                } catch let error as AgentClientError {
                    try expectEqual(error, .notFound("transfer"))
                }
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
        } else if url.path == "/v1/files/metadata", query("path") == "." {
            finish(
                body: #"{"path":"/Users/dev","name":"dev","kind":"directory","hidden":false,"readable":true,"sensitive":false}"#
            )
        } else if url.path == "/v1/files/metadata",
                  query("path") == "/Users/dev/README.md"
        {
            finish(
                body: #"{"path":"/Users/dev/README.md","name":"README.md","kind":"file","size":12,"hidden":false,"readable":true,"sensitive":false}"#
            )
        } else if url.path == "/v1/files/list", query("path") == "/Users/dev" {
            finish(
                body: #"[{"path":"/Users/dev/README.md","name":"README.md","kind":"file","size":12,"hidden":false,"readable":true,"sensitive":false},{"path":"/Users/dev/work","name":"work","kind":"directory","hidden":false,"readable":true,"sensitive":false}]"#
            )
        } else if url.path == "/v1/files/list", query("path") == "/Users/dev/work" {
            finish(
                body: #"[{"path":"/Users/dev/work/api","name":"api","kind":"directory","hidden":false,"readable":true,"sensitive":false}]"#
            )
        } else if url.path == "/v1/files/list", query("path") == "/outside" {
            finish(status: 403, body: #"{"error":"path_outside_root"}"#)
        } else if url.path == "/v1/files/preview",
                  query("path") == "/Users/dev/README.md",
                  query("maxBytes") == "5"
        {
            finish(data: Data("hello".utf8), contentType: "application/octet-stream")
        } else if url.path == "/v1/transfers/create", request.httpMethod == "POST" {
            let json = (try? JSONSerialization.jsonObject(with: requestBody()))
                as? [String: Any]
            if json?["path"] as? String == "/Users/dev/work/new.bin",
               json?["expectedSha256"] as? String == "digest-123",
               json?["conflictPolicy"] == nil
            {
                finish(
                    body: #"{"id":"upload-1","destination":"/Users/dev/work/new.bin"}"#
                )
            } else if json?["path"] as? String == "/Users/dev/work/existing.txt" {
                finish(
                    status: 409,
                    body: #"{"error":"conflict","existingPath":"/Users/dev/work/existing.txt","existingSize":42}"#
                )
            } else {
                finish(status: 400, body: #"{"error":"bad_create"}"#)
            }
        } else if url.path == "/v1/transfers/upload-1/chunk",
                  request.httpMethod == "POST"
        {
            let json = (try? JSONSerialization.jsonObject(with: requestBody()))
                as? [String: Any]
            guard json?["offset"] as? Int == 1_048_576,
                  json?["data"] as? String == "eg=="
            else {
                finish(status: 400, body: #"{"error":"bad_chunk"}"#)
                return
            }
            finish(status: 204, body: "")
        } else if url.path == "/v1/transfers/upload-1/finish",
                  request.httpMethod == "POST"
        {
            finish(status: 204, body: "")
        } else if url.path == "/v1/transfers/upload-1/cancel",
                  request.httpMethod == "POST"
        {
            finish(status: 204, body: "")
        } else {
            finish(status: 404, body: "{}")
        }
    }

    private func query(_ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private func finish(status: Int = 200, body: String) {
        finish(data: Data(body.utf8), status: status, contentType: "application/json")
    }

    private func finish(
        data: Data, status: Int = 200, contentType: String
    ) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
