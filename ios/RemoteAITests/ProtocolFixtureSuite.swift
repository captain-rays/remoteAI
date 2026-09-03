import Foundation
import RemoteAIKit
import RemoteAITestKit

/// Decoding contract for the frozen v1 protocol.
///
/// The canonical fixtures live in `protocol/v1/fixtures`, which is owned by
/// lane A. Lane B may not create files there, so the same JSON shapes are
/// embedded here. Integration must reconcile these literals against the
/// generated fixtures before the lanes are merged.
public enum ProtocolFixtureSuite {

    static func data(_ json: String) -> Data { Data(json.utf8) }

    static let providerStatusJSON = """
    {
      "protocolVersion": 1,
      "messageId": "9F2D6C64-9F0B-4C2F-9E2B-2C3E4F5A6B7C",
      "kind": "response",
      "requestId": "1D1B7E4C-5B0A-4A66-9E10-8C3E2F1A0B99",
      "sequence": 1,
      "conversationId": null,
      "type": "provider.status",
      "payload": {
        "providers": [
          {
            "provider": "codex",
            "available": true,
            "executablePath": "/opt/homebrew/bin/codex",
            "version": "0.144.4"
          },
          {
            "provider": "claude",
            "available": false,
            "reason": "not_installed"
          }
        ]
      }
    }
    """

    static let catalogJSON = """
    {
      "projects": [
        {
          "id": "codex:/Users/dev/work/api",
          "provider": "codex",
          "canonicalPath": "/Users/dev/work/api",
          "displayPath": "~/work/api",
          "title": "api",
          "updatedAt": "2026-09-02T10:15:00Z",
          "available": true
        },
        {
          "id": "claude:/Users/dev/work/api",
          "provider": "claude",
          "canonicalPath": "/Users/dev/work/api",
          "displayPath": "~/work/api",
          "title": "api",
          "updatedAt": "2026-09-02T11:00:00Z",
          "available": true
        }
      ],
      "conversations": [
        {
          "id": "codex-daily-1",
          "provider": "codex",
          "kind": "daily",
          "title": "Shell one-liners",
          "updatedAt": "2026-09-03T08:00:00Z",
          "status": "idle"
        },
        {
          "id": "codex-project-1",
          "provider": "codex",
          "kind": "project",
          "title": "Refactor router",
          "projectId": "codex:/Users/dev/work/api",
          "projectPath": "/Users/dev/work/api",
          "updatedAt": "2026-09-03T09:30:00Z",
          "status": "running"
        },
        {
          "id": "claude-daily-1",
          "provider": "claude",
          "kind": "daily",
          "title": "Trip planning",
          "updatedAt": "2026-09-01T20:00:00Z",
          "status": "brand_new_status_from_the_future"
        }
      ]
    }
    """

    static let approvalJSON = """
    {
      "id": "approval-1",
      "provider": "codex",
      "conversationId": "codex-project-1",
      "category": "command",
      "title": "Run a shell command",
      "detail": "rm -rf build/",
      "cwd": "/Users/dev/work/api",
      "risk": "high",
      "createdAt": "2026-09-03T09:31:00Z"
    }
    """

    static let fileEntryJSON = """
    {
      "path": "/Users/dev/work/api/README.md",
      "name": "README.md",
      "kind": "file",
      "size": 2048,
      "modifiedAt": "2026-09-02T10:15:00Z",
      "hidden": false,
      "readable": true,
      "sensitive": false
    }
    """

    static func eventJSON(sequence: Int, type: String, payload: String) -> String {
        """
        {
          "protocolVersion": 1,
          "messageId": "evt-\(sequence)",
          "kind": "event",
          "requestId": null,
          "sequence": \(sequence),
          "conversationId": "codex-project-1",
          "type": "\(type)",
          "payload": \(payload)
        }
        """
    }

    public static let suite = TestSuite(
        name: "ProtocolFixtureSuite",
        cases: [
            TestCase("decodes a provider status response") {
                let envelope = try ProtocolCoding.decodeResponse(
                    ProviderStatusPayload.self,
                    from: data(providerStatusJSON)
                )
                try expectEqual(envelope.protocolVersion, 1)
                try expectEqual(envelope.kind, .response)
                try expectEqual(envelope.payload.providers.count, 2)

                let codex = envelope.payload.providers[0]
                try expectEqual(codex.provider, .codex)
                try expectTrue(codex.available)
                try expectEqual(codex.version, "0.144.4")
                try expectEqual(codex.executablePath, "/opt/homebrew/bin/codex")

                let claude = envelope.payload.providers[1]
                try expectEqual(claude.provider, .claude)
                try expectFalse(claude.available)
                try expectEqual(claude.reason, "not_installed")
                try expectNil(claude.version)
            },

            TestCase("same canonical path yields different project ids per provider") {
                let catalog = try ProtocolCoding.decoder.decode(
                    CatalogPayload.self, from: data(catalogJSON)
                )
                let codex = try expectNotNil(catalog.projects.first { $0.provider == .codex })
                let claude = try expectNotNil(catalog.projects.first { $0.provider == .claude })
                try expectEqual(codex.canonicalPath, claude.canonicalPath)
                try expectFalse(codex.id == claude.id, "project ids must be provider-scoped")
            },

            TestCase("decodes daily and project conversation summaries") {
                let catalog = try ProtocolCoding.decoder.decode(
                    CatalogPayload.self, from: data(catalogJSON)
                )
                let daily = try expectNotNil(catalog.conversations.first { $0.id == "codex-daily-1" })
                try expectEqual(daily.kind, .daily)
                try expectNil(daily.projectId)
                try expectNil(daily.projectPath)

                let project = try expectNotNil(
                    catalog.conversations.first { $0.id == "codex-project-1" }
                )
                try expectEqual(project.kind, .project)
                try expectEqual(project.projectId, "codex:/Users/dev/work/api")
                try expectEqual(project.projectPath, "/Users/dev/work/api")
                try expectEqual(project.status, .running)
            },

            TestCase("unknown conversation status degrades to unknown") {
                let catalog = try ProtocolCoding.decoder.decode(
                    CatalogPayload.self, from: data(catalogJSON)
                )
                let claude = try expectNotNil(catalog.conversations.first { $0.id == "claude-daily-1" })
                try expectEqual(claude.status, .unknown)
            },

            TestCase("decodes a delta event") {
                let json = eventJSON(
                    sequence: 7,
                    type: "conversation.delta",
                    payload: #"{"messageId": "m1", "role": "assistant", "text": "hel"}"#
                )
                let envelope = try ProtocolCoding.decodeEvent(from: data(json))
                try expectEqual(envelope.sequence, 7)
                try expectEqual(envelope.conversationId, "codex-project-1")
                guard case let .delta(delta) = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .delta, got \(envelope.event)", file: #filePath, line: #line
                    )
                }
                try expectEqual(delta.messageId, "m1")
                try expectEqual(delta.text, "hel")
            },

            TestCase("decodes an approval requested event") {
                let json = eventJSON(sequence: 8, type: "approval.requested", payload: approvalJSON)
                let envelope = try ProtocolCoding.decodeEvent(from: data(json))
                guard case let .approvalRequested(request) = envelope.event else {
                    throw ExpectationFailure(
                        message: "expected .approvalRequested, got \(envelope.event)",
                        file: #filePath, line: #line
                    )
                }
                try expectEqual(request.id, "approval-1")
                try expectEqual(request.provider, .codex)
                try expectEqual(request.category, .command)
                try expectEqual(request.detail, "rm -rf build/")
                try expectEqual(request.cwd, "/Users/dev/work/api")
                try expectEqual(request.risk, .high)
            },

            TestCase("unknown event type degrades to unsupported without throwing") {
                let json = eventJSON(
                    sequence: 9,
                    type: "conversation.telepathy",
                    payload: #"{"anything": [1, 2, 3]}"#
                )
                let envelope = try ProtocolCoding.decodeEvent(from: data(json))
                try expectEqual(envelope.rawType, "conversation.telepathy")
                try expectEqual(envelope.event, .unsupported(rawType: "conversation.telepathy"))
            },

            TestCase("known event type with malformed payload degrades to unsupported") {
                let json = eventJSON(sequence: 10, type: "conversation.delta", payload: #"{"nope": 1}"#)
                let envelope = try ProtocolCoding.decodeEvent(from: data(json))
                try expectEqual(envelope.event, .unsupported(rawType: "conversation.delta"))
            },

            TestCase("future protocol major version is rejected as upgrade_required") {
                let json = """
                {
                  "protocolVersion": 2,
                  "messageId": "evt-99",
                  "kind": "event",
                  "requestId": null,
                  "sequence": 99,
                  "conversationId": null,
                  "type": "conversation.delta",
                  "payload": {}
                }
                """
                let error = try await expectThrows {
                    _ = try ProtocolCoding.decodeEvent(from: data(json))
                }
                try expectEqual(
                    error as? ProtocolError, .upgradeRequired(found: 2, supported: 1)
                )
            },

            TestCase("a response carrying an agent error is surfaced, not decoded") {
                let json = """
                {
                  "protocolVersion": 1,
                  "messageId": "r1",
                  "kind": "response",
                  "requestId": "q1",
                  "sequence": 2,
                  "conversationId": null,
                  "type": "files.list",
                  "error": { "code": "path_traversal", "message": "rejected" }
                }
                """
                let error = try await expectThrows {
                    _ = try ProtocolCoding.decodeResponse(CatalogPayload.self, from: data(json))
                }
                try expectEqual(
                    error as? ProtocolError,
                    .agentError(code: "path_traversal", message: "rejected")
                )
            },

            TestCase("a gateway type error payload is surfaced by stable code") {
                let json = """
                {
                  "protocolVersion": 1,
                  "messageId": "r2",
                  "kind": "response",
                  "requestId": "q2",
                  "type": "error",
                  "payload": {
                    "code": "provider_operation_failed",
                    "message": "vendor stderr and prompt must not escape"
                  }
                }
                """
                let error = try await expectThrows {
                    _ = try ProtocolCoding.decodeResponse(
                        EmptyPayload.self, from: data(json)
                    )
                }
                try expectEqual(
                    error as? ProtocolError,
                    .agentError(code: "provider_operation_failed", message: "")
                )
            },

            TestCase("decodes a file entry") {
                let entry = try ProtocolCoding.decoder.decode(FileEntry.self, from: data(fileEntryJSON))
                try expectEqual(entry.name, "README.md")
                try expectEqual(entry.kind, .file)
                try expectEqual(entry.size, 2048)
                try expectFalse(entry.hidden)
                try expectTrue(entry.readable)
                try expectFalse(entry.sensitive)
            },

            TestCase("approval decisions encode to the frozen wire values") {
                try expectEqual(ApprovalDecision.allowOnce.rawValue, "allow_once")
                try expectEqual(ApprovalDecision.deny.rawValue, "deny")
                try expectEqual(ApprovalDecision.allCases.count, 2)
            },

            TestCase("request envelopes carry the frozen required fields") {
                let request = RequestEnvelope(
                    type: .conversationSend,
                    conversationId: "codex-daily-1",
                    payload: ConversationSendPayload(
                        provider: .codex, conversationId: "codex-daily-1", text: "hi"
                    )
                )
                let encoded = try ProtocolCoding.encoder.encode(request)
                let object = try expectNotNil(
                    try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                )
                try expectEqual(object["protocolVersion"] as? Int, 1)
                try expectEqual(object["kind"] as? String, "request")
                try expectEqual(object["type"] as? String, "conversation.send")
                try expectEqual(object["conversationId"] as? String, "codex-daily-1")
                try expectFalse((object["messageId"] as? String ?? "").isEmpty)
            },
        ]
    )

    private struct EmptyPayload: Decodable, Sendable {}
}
