import Foundation
import RemoteAIKit
import RemoteAITestKit

/// The mock agent is lane B's stand-in for the Rust agent. These tests pin the
/// product rules that must hold in the *data* layer, not merely in the UI.
public enum MockAgentClientSuite {

    static func drain(
        _ client: MockAgentClient,
        untilTypeMatching predicate: @escaping @Sendable (ConversationEvent) -> Bool,
        limit: Int = 64
    ) async throws -> [EventEnvelope] {
        var collected: [EventEnvelope] = []
        for await envelope in client.events {
            collected.append(envelope)
            if predicate(envelope.event) || collected.count >= limit { break }
        }
        return collected
    }

    public static let suite = TestSuite(
        name: "MockAgentClientSuite",
        cases: [
            TestCase("daily conversation lists never mix providers") {
                let client = MockAgentClient()
                let codex = try await client.listDailyConversations(provider: .codex)
                let claude = try await client.listDailyConversations(provider: .claude)

                try expectTrue(codex.allSatisfy { $0.provider == .codex })
                try expectTrue(claude.allSatisfy { $0.provider == .claude })
                try expectTrue(!codex.isEmpty && !claude.isEmpty)

                let codexIds = Set(codex.map(\.id))
                let claudeIds = Set(claude.map(\.id))
                try expectTrue(codexIds.isDisjoint(with: claudeIds), "no shared conversation ids")
            },

            TestCase("daily conversations are never bound to a project") {
                let client = MockAgentClient()
                for provider in ProviderId.allCases {
                    let daily = try await client.listDailyConversations(provider: provider)
                    try expectTrue(daily.allSatisfy { $0.kind == .daily })
                    try expectTrue(daily.allSatisfy { $0.projectId == nil })
                    try expectTrue(daily.allSatisfy { $0.projectPath == nil })
                }
            },

            TestCase("the same canonical path yields provider-scoped project ids") {
                let client = MockAgentClient()
                let codex = try await client.listProjects(provider: .codex)
                let claude = try await client.listProjects(provider: .claude)

                let shared = "/Users/dev/work/api"
                let codexProject = try expectNotNil(codex.first { $0.canonicalPath == shared })
                let claudeProject = try expectNotNil(claude.first { $0.canonicalPath == shared })
                try expectFalse(codexProject.id == claudeProject.id)
                try expectEqual(codexProject.provider, .codex)
                try expectEqual(claudeProject.provider, .claude)
            },

            TestCase("project lists never mix providers") {
                let client = MockAgentClient()
                let codex = try await client.listProjects(provider: .codex)
                let claude = try await client.listProjects(provider: .claude)
                try expectTrue(codex.allSatisfy { $0.provider == .codex })
                try expectTrue(claude.allSatisfy { $0.provider == .claude })
                try expectTrue(Set(codex.map(\.id)).isDisjoint(with: Set(claude.map(\.id))))
            },

            TestCase("project conversations are scoped to one provider and one project") {
                let client = MockAgentClient()
                let projects = try await client.listProjects(provider: .codex)
                let project = try expectNotNil(projects.first)
                let conversations = try await client.listProjectConversations(
                    provider: .codex, projectId: project.id
                )
                try expectTrue(!conversations.isEmpty)
                try expectTrue(conversations.allSatisfy { $0.provider == .codex })
                try expectTrue(conversations.allSatisfy { $0.kind == .project })
                try expectTrue(conversations.allSatisfy { $0.projectId == project.id })
            },

            TestCase("asking for another provider's project is rejected at the data layer") {
                let client = MockAgentClient()
                let codexProjects = try await client.listProjects(provider: .codex)
                let codexProject = try expectNotNil(codexProjects.first)
                let error = try await expectThrows {
                    _ = try await client.listProjectConversations(
                        provider: .claude, projectId: codexProject.id
                    )
                }
                try expectEqual(error as? AgentClientError, .providerMismatch)
            },

            TestCase("starting a project conversation requires a working directory") {
                let client = MockAgentClient()
                let error = try await expectThrows {
                    _ = try await client.startConversation(
                        provider: .codex, kind: .project, cwd: nil
                    )
                }
                try expectEqual(error as? AgentClientError, .invalidRequest("project_requires_cwd"))
            },

            TestCase("starting a daily conversation produces an unbound session") {
                let client = MockAgentClient()
                let created = try await client.startConversation(
                    provider: .claude, kind: .daily, cwd: nil
                )
                try expectEqual(created.provider, .claude)
                try expectEqual(created.kind, .daily)
                try expectNil(created.projectId)

                let daily = try await client.listDailyConversations(provider: .claude)
                try expectTrue(daily.contains { $0.id == created.id })

                let codexDaily = try await client.listDailyConversations(provider: .codex)
                try expectFalse(
                    codexDaily.contains { $0.id == created.id },
                    "a new Claude session must not appear under Codex"
                )
            },

            TestCase("sending a message streams ordered deltas and completes the turn") {
                let client = MockAgentClient()
                let conversation = try await client.listDailyConversations(provider: .codex)[0]
                try await client.send(
                    provider: .codex, conversationId: conversation.id, text: "hello"
                )

                let events = try await drain(client) {
                    if case .turnCompleted = $0 { return true }
                    return false
                }
                let sequences = events.map(\.sequence)
                try expectEqual(sequences, sequences.sorted(), "sequence numbers must ascend")
                try expectEqual(Set(sequences).count, sequences.count, "no duplicate sequences")
                try expectTrue(events.allSatisfy { $0.conversationId == conversation.id })

                let text = events.compactMap { event -> String? in
                    if case let .delta(delta) = event.event { return delta.text }
                    return nil
                }.joined()
                try expectFalse(text.isEmpty)
            },

            TestCase("interrupting an active turn emits turn.interrupted") {
                let client = MockAgentClient()
                let conversation = try await client.listDailyConversations(provider: .codex)[0]
                try await client.send(
                    provider: .codex, conversationId: conversation.id, text: "long task"
                )
                try await client.interrupt(provider: .codex, conversationId: conversation.id)

                let events = try await drain(client) {
                    if case .turnInterrupted = $0 { return true }
                    return false
                }
                try expectTrue(
                    events.contains {
                        if case .turnInterrupted = $0.event { return true }
                        return false
                    }
                )
            },

            TestCase("an approval can only be resolved as allow_once or deny") {
                let client = MockAgentClient()
                let conversation = try await client.listDailyConversations(provider: .codex)[0]
                try await client.send(
                    provider: .codex, conversationId: conversation.id, text: "needs approval"
                )

                let events = try await drain(client) {
                    if case .approvalRequested = $0 { return true }
                    return false
                }
                let request = try expectNotNil(
                    events.compactMap { event -> ApprovalRequest? in
                        if case let .approvalRequested(request) = event.event { return request }
                        return nil
                    }.first
                )
                try await client.decideApproval(id: request.id, decision: .deny)

                let resolved = try await drain(client) {
                    if case .approvalResolved = $0 { return true }
                    return false
                }
                let resolution = try expectNotNil(
                    resolved.compactMap { event -> ApprovalResolution? in
                        if case let .approvalResolved(resolution) = event.event { return resolution }
                        return nil
                    }.first
                )
                try expectEqual(resolution.decision, .deny)
            },

            TestCase("deciding an unknown approval is rejected") {
                let client = MockAgentClient()
                let error = try await expectThrows {
                    try await client.decideApproval(id: "nope", decision: .allowOnce)
                }
                try expectEqual(error as? AgentClientError, .notFound("approval:nope"))
            },

            TestCase("path traversal is rejected before any listing happens") {
                let client = MockAgentClient()
                let error = try await expectThrows {
                    _ = try await client.listFiles(path: "/Users/dev/work/../../../etc", showHidden: false)
                }
                try expectEqual(error as? AgentClientError, .rejected("path_traversal"))
            },

            TestCase("hidden entries are withheld until explicitly requested") {
                let client = MockAgentClient()
                let plain = try await client.listFiles(path: "/Users/dev", showHidden: false)
                try expectFalse(plain.entries.contains { $0.hidden })

                let revealed = try await client.listFiles(path: "/Users/dev", showHidden: true)
                try expectTrue(revealed.entries.contains { $0.hidden && $0.sensitive })
            },

            TestCase("an upload onto an existing name reports a conflict and writes nothing") {
                let client = MockAgentClient()
                let before = try await client.listFiles(path: "/Users/dev/work/api", showHidden: false)

                let ticket = try await client.createTransfer(
                    TransferRequest(
                        direction: .upload,
                        name: "README.md",
                        remoteDirectory: "/Users/dev/work/api",
                        byteCount: 12,
                        conflictPolicy: nil
                    )
                )
                let conflict = try expectNotNil(ticket.conflict)
                try expectEqual(conflict.existingPath, "/Users/dev/work/api/README.md")

                let after = try await client.listFiles(path: "/Users/dev/work/api", showHidden: false)
                try expectEqual(after.entries, before.entries, "destination must be untouched")
            },

            TestCase("keep_both resolves a conflict to a new destination path") {
                let client = MockAgentClient()
                let ticket = try await client.createTransfer(
                    TransferRequest(
                        direction: .upload,
                        name: "README.md",
                        remoteDirectory: "/Users/dev/work/api",
                        byteCount: 12,
                        conflictPolicy: .keepBoth
                    )
                )
                try expectNil(ticket.conflict)
                try expectFalse(ticket.destinationPath == "/Users/dev/work/api/README.md")
                try expectTrue(ticket.destinationPath.hasPrefix("/Users/dev/work/api/README"))
            },

            TestCase("overwrite resolves a conflict to the original destination path") {
                let client = MockAgentClient()
                let ticket = try await client.createTransfer(
                    TransferRequest(
                        direction: .upload,
                        name: "README.md",
                        remoteDirectory: "/Users/dev/work/api",
                        byteCount: 12,
                        conflictPolicy: .overwrite
                    )
                )
                try expectNil(ticket.conflict)
                try expectEqual(ticket.destinationPath, "/Users/dev/work/api/README.md")
            },

            TestCase("browsing and chatting never issue a transfer request") {
                let client = MockAgentClient()
                _ = try await client.providerStatus()
                for provider in ProviderId.allCases {
                    _ = try await client.listDailyConversations(provider: provider)
                    let projects = try await client.listProjects(provider: provider)
                    for project in projects {
                        _ = try await client.listProjectConversations(
                            provider: provider, projectId: project.id
                        )
                    }
                }
                _ = try await client.listFiles(path: "/Users/dev/work/api", showHidden: false)
                _ = try await client.filePreview(path: "/Users/dev/work/api/README.md", maxBytes: 4096)

                try expectEqual(
                    await client.transferRequestCount, 0,
                    "no automatic synchronisation is allowed"
                )
            },
        ]
    )
}
