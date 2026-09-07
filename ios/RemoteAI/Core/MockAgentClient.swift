import Foundation

/// Deterministic in-memory agent used to develop and test the client without
/// the Rust agent.
///
/// Response streams are *scripted* from the message text so tests never depend
/// on timing:
///
/// - text containing `approval` — streams, then raises an approval request and
///   keeps the turn open until a decision arrives;
/// - text containing `long` — streams and keeps the turn open so it can be
///   interrupted;
/// - text containing `fail` — rejects the *first* attempt per conversation so
///   the retry path can be exercised, then behaves normally;
/// - anything else — streams and completes the turn.
///
/// A conversation whose `writeState` is `.busy` rejects every send with
/// `session_busy` while staying fully readable, mirroring the agent's
/// single-writer rule.
public actor MockAgentClient: AgentClient {

    private nonisolated let fanout = EventFanout()

    /// A fresh delivery of the feed per caller: two open transcripts must both
    /// see every event.
    public nonisolated var events: AsyncStream<EventEnvelope> { fanout.stream() }

    private var sequence = 0
    private var conversations: [ConversationSummary]
    private var projects: [ProjectSummary]
    private var directories: [String: [FileEntry]]
    private var previews: [String: String]
    private var history: [String: [EventEnvelope]] = [:]
    /// Events per history page: five exchanges, matching what the agent serves.
    private static let historyPageEvents = 10
    /// Delay before a history page is answered. Real conversations do not load
    /// instantly, and several transcript behaviours only go wrong when the
    /// first page lands after the screen is already on show.
    private var historyDelay: Duration = .zero

    public func setHistoryDelay(_ delay: Duration) { historyDelay = delay }
    private var pendingApprovals: [String: ApprovalRequest] = [:]
    private var activeTurns: [String: String] = [:]
    /// Conversations whose scripted `fail` rejection has already been served.
    private var scriptedFailures: Set<String> = []
    private var tickets: [String: TransferTicket] = [:]
    private var uploadedChunks: [String: [Int: Data]] = [:]
    private var audit: [AuditEntry] = []
    /// Accounts the mac has snapshots for, per provider.
    private var savedAccounts: [ProviderId: [AccountEntry]] = [
        .codex: [
            AccountEntry(label: "work", display: "work@example.com", isCurrent: true)
        ],
        .claude: [],
    ]
    private var providerLogins: [ProviderId: ProviderLogin] = [
        .codex: ProviderLogin(state: .loggedIn, account: "work@example.com"),
        .claude: ProviderLogin(
            state: .loggedIn, account: "someone@example.com", detail: "Mock org · team"
        ),
    ]
    private var mockLogins: [ProviderId: MockLogin] = [:]
    private var lastLoginMessages: [ProviderId: String] = [:]

    /// Number of `transfers.*` calls this client has been asked to perform.
    /// The regression test for "no automatic synchronisation" asserts this is
    /// zero while the app is merely browsing.
    public private(set) var transferRequestCount = 0
    public private(set) var lastCreatedTransferRequest: TransferRequest?

    public init() {

        let day = MockAgentClient.date
        self.projects = [
            ProjectSummary(
                id: "codex:/Users/dev/work/api",
                provider: .codex,
                canonicalPath: "/Users/dev/work/api",
                displayPath: "~/work/api",
                title: "api",
                updatedAt: day("2026-09-03T09:30:00Z"),
                available: true
            ),
            ProjectSummary(
                id: "codex:/Users/dev/work/site",
                provider: .codex,
                canonicalPath: "/Users/dev/work/site",
                displayPath: "~/work/site",
                title: "site",
                updatedAt: day("2026-08-30T14:00:00Z"),
                available: true
            ),
            ProjectSummary(
                id: "claude:/Users/dev/work/api",
                provider: .claude,
                canonicalPath: "/Users/dev/work/api",
                displayPath: "~/work/api",
                title: "api",
                updatedAt: day("2026-09-02T18:10:00Z"),
                available: true
            ),
            ProjectSummary(
                id: "claude:/Users/dev/notes",
                provider: .claude,
                canonicalPath: "/Users/dev/notes",
                displayPath: "~/notes",
                title: "notes",
                updatedAt: day("2026-09-01T07:45:00Z"),
                available: true
            ),
        ]

        self.conversations = [
            ConversationSummary(
                id: "codex-daily-1", provider: .codex, kind: .daily,
                title: "Shell one-liners",
                updatedAt: day("2026-09-03T08:00:00Z"), status: .idle
            ),
            ConversationSummary(
                id: "codex-daily-2", provider: .codex, kind: .daily,
                title: "Regex help",
                updatedAt: day("2026-09-02T12:00:00Z"), status: .idle
            ),
            ConversationSummary(
                id: "codex-project-api-1", provider: .codex, kind: .project,
                title: "Refactor router",
                projectId: "codex:/Users/dev/work/api",
                projectPath: "/Users/dev/work/api",
                updatedAt: day("2026-09-03T09:30:00Z"), status: .idle
            ),
            ConversationSummary(
                id: "codex-project-site-1", provider: .codex, kind: .project,
                title: "Fix hero layout",
                projectId: "codex:/Users/dev/work/site",
                projectPath: "/Users/dev/work/site",
                updatedAt: day("2026-08-30T14:00:00Z"), status: .idle
            ),
            ConversationSummary(
                id: "claude-daily-1", provider: .claude, kind: .daily,
                title: "Trip planning",
                updatedAt: day("2026-09-01T20:00:00Z"), status: .idle
            ),
            // Held by another writer (desktop app or terminal). Readable here,
            // never writable.
            ConversationSummary(
                id: "claude-daily-2", provider: .claude, kind: .daily,
                title: "Reading list",
                updatedAt: day("2026-08-29T19:00:00Z"), status: .idle,
                writeState: .busy, writeBlockCode: "session_busy"
            ),
            ConversationSummary(
                id: "claude-project-api-1", provider: .claude, kind: .project,
                title: "Write API docs",
                projectId: "claude:/Users/dev/work/api",
                projectPath: "/Users/dev/work/api",
                updatedAt: day("2026-09-02T18:10:00Z"), status: .idle
            ),
            ConversationSummary(
                id: "claude-project-notes-1", provider: .claude, kind: .project,
                title: "Summarise notes",
                projectId: "claude:/Users/dev/notes",
                projectPath: "/Users/dev/notes",
                updatedAt: day("2026-09-01T07:45:00Z"), status: .idle
            ),
        ]

        self.directories = [
            "/Users/dev": [
                FileEntry(path: "/Users/dev/work", name: "work", kind: .directory),
                FileEntry(path: "/Users/dev/notes", name: "notes", kind: .directory),
                FileEntry(
                    path: "/Users/dev/.ssh", name: ".ssh", kind: .directory,
                    hidden: true, readable: true, sensitive: true
                ),
                FileEntry(
                    path: "/Users/dev/README.md", name: "README.md", kind: .file,
                    size: 128, modifiedAt: day("2026-08-01T00:00:00Z")
                ),
            ],
            "/Users/dev/work": [
                FileEntry(path: "/Users/dev/work/api", name: "api", kind: .directory),
                FileEntry(path: "/Users/dev/work/site", name: "site", kind: .directory),
            ],
            "/Users/dev/work/api": [
                FileEntry(path: "/Users/dev/work/api/src", name: "src", kind: .directory),
                FileEntry(
                    path: "/Users/dev/work/api/README.md", name: "README.md", kind: .file,
                    size: 2048, modifiedAt: day("2026-09-02T10:15:00Z")
                ),
                FileEntry(
                    path: "/Users/dev/work/api/.env", name: ".env", kind: .file,
                    size: 64, modifiedAt: day("2026-09-02T10:15:00Z"),
                    hidden: true, readable: true, sensitive: true
                ),
            ],
            "/Users/dev/work/api/src": [
                FileEntry(
                    path: "/Users/dev/work/api/src/main.swift", name: "main.swift", kind: .file,
                    size: 512, modifiedAt: day("2026-09-02T10:15:00Z")
                )
            ],
            "/Users/dev/work/site": [
                FileEntry(
                    path: "/Users/dev/work/site/index.html", name: "index.html", kind: .file,
                    size: 900, modifiedAt: day("2026-08-30T14:00:00Z")
                )
            ],
            "/Users/dev/notes": [
                FileEntry(
                    path: "/Users/dev/notes/ideas.md", name: "ideas.md", kind: .file,
                    size: 300, modifiedAt: day("2026-09-01T07:45:00Z")
                )
            ],
        ]

        self.previews = [
            "/Users/dev/work/api/README.md": "# api\n\nA sample service.\n",
            "/Users/dev/notes/ideas.md": "- ship v1\n",
        ]

        self.audit = [
            AuditEntry(
                id: "audit-1", timestamp: day("2026-09-03T09:31:00Z"),
                action: "approval.decide", provider: .codex,
                conversationId: "codex-project-api-1",
                targetPath: nil, outcome: "deny"
            ),
            AuditEntry(
                id: "audit-2", timestamp: day("2026-09-03T09:35:00Z"),
                action: "transfers.finish", provider: nil, conversationId: nil,
                targetPath: "/Users/dev/work/api/notes.txt", outcome: "ok"
            ),
        ]

        // Transcripts the agent would have synchronized from the provider
        // before this device ever opened the session. They are written straight
        // into `history` rather than streamed, because nothing on this device
        // produced them.
        var seeded = 0
        func envelope(
            _ conversationId: String, _ rawType: String, _ event: ConversationEvent
        ) -> EventEnvelope {
            seeded += 1
            return EventEnvelope(
                messageId: "seed-\(seeded)",
                sequence: seeded,
                conversationId: conversationId,
                rawType: rawType,
                event: event
            )
        }

        self.history = [
            "claude-daily-1": [
                envelope(
                    "claude-daily-1", "conversation.user_message",
                    .userMessage(
                        MessagePayload(
                            messageId: "claude-seed-user-1", role: .user,
                            text: "Plan the trip and show the parser."
                        )
                    )
                ),
                envelope(
                    "claude-daily-1", "conversation.reasoning_completed",
                    .reasoningCompleted(
                        ReasoningPayload(
                            reasoningId: "claude-seed-reason-1",
                            text: "Weighing two itineraries."
                        )
                    )
                ),
                envelope(
                    "claude-daily-1", "conversation.message_completed",
                    .messageCompleted(
                        MessagePayload(
                            messageId: "claude-seed-assistant-1", role: .assistant,
                            text: """
                                Here is the **parser** you asked for:

                                ```swift
                                let trip = Trip(days: 3)
                                ```

                                > Fences stay intact while streaming.
                                """
                        )
                    )
                ),
                envelope(
                    "claude-daily-1", "turn.completed",
                    .turnCompleted(TurnPayload(turnId: "claude-seed-turn-1"))
                ),
            ],
            "claude-daily-2": [
                envelope(
                    "claude-daily-2", "conversation.user_message",
                    .userMessage(
                        MessagePayload(
                            messageId: "claude-busy-user-1", role: .user,
                            text: "Which book is next?"
                        )
                    )
                ),
                envelope(
                    "claude-daily-2", "conversation.message_completed",
                    .messageCompleted(
                        MessagePayload(
                            messageId: "claude-busy-assistant-1", role: .assistant,
                            text: "Finish **Dune**, then start the essays."
                        )
                    )
                ),
                envelope(
                    "claude-daily-2", "turn.completed",
                    .turnCompleted(TurnPayload(turnId: "claude-busy-turn-1"))
                ),
            ],
            "codex-project-api-1": [
                envelope(
                    "codex-project-api-1", "conversation.user_message",
                    .userMessage(
                        MessagePayload(
                            messageId: "codex-seed-user-1", role: .user,
                            text: "Show the router table."
                        )
                    )
                ),
                envelope(
                    "codex-project-api-1", "conversation.message_completed",
                    .messageCompleted(
                        MessagePayload(
                            messageId: "codex-seed-assistant-1", role: .assistant,
                            text: """
                                The **router** table is generated by:

                                ```bash
                                swift run routes list
                                ```
                                """
                        )
                    )
                ),
                envelope(
                    "codex-project-api-1", "turn.completed",
                    .turnCompleted(TurnPayload(turnId: "codex-seed-turn-1"))
                ),
            ],
        ]

        // One conversation several pages deep, so the transcript's
        // "open at the newest end, load earlier on scroll" behaviour can be
        // exercised without a live provider.
        for turn in 1...20 {
            history["claude-project-api-1", default: []].append(
                EventEnvelope(
                    messageId: "mock-user-\(turn)",
                    sequence: turn * 2 - 1,
                    conversationId: "claude-project-api-1",
                    rawType: "conversation.user_message",
                    event: .userMessage(
                        MessagePayload(
                            messageId: "mock-user-\(turn)", role: .user, text: "question \(turn)"
                        )
                    )
                )
            )
            history["claude-project-api-1", default: []].append(
                EventEnvelope(
                    messageId: "mock-assistant-\(turn)",
                    sequence: turn * 2,
                    conversationId: "claude-project-api-1",
                    rawType: "conversation.message_completed",
                    event: .messageCompleted(
                        MessagePayload(
                            messageId: "mock-assistant-\(turn)", role: .assistant,
                            text: "answer \(turn)"
                        )
                    )
                )
            )
        }
        // Live events must never reuse a seeded sequence number.
        self.sequence = seeded
    }

    private nonisolated static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - Event emission

    @discardableResult
    private func emit(
        _ event: ConversationEvent, rawType: String, conversationId: String?
    ) -> EventEnvelope {
        sequence += 1
        let envelope = EventEnvelope(
            sequence: sequence,
            conversationId: conversationId,
            rawType: rawType,
            event: event
        )
        if let conversationId {
            history[conversationId, default: []].append(envelope)
        }
        fanout.yield(envelope)
        return envelope
    }

    // MARK: - AgentClient

    public func providerStatus() async throws -> [ProviderStatus] {
        [
            ProviderStatus(
                provider: .codex, available: true,
                executablePath: "/opt/homebrew/bin/codex", version: "0.144.4"
            ),
            ProviderStatus(
                provider: .claude, available: true,
                executablePath: "/opt/homebrew/bin/claude", version: "2.1.210"
            ),
        ]
    }

    public func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] {
        conversations
            .filter { $0.provider == provider && $0.kind == .daily }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func listProjects(provider: ProviderId) async throws -> [ProjectSummary] {
        projects
            .filter { $0.provider == provider }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func listProjectConversations(
        provider: ProviderId, projectId: String
    ) async throws -> [ConversationSummary] {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw AgentClientError.notFound("project:\(projectId)")
        }
        guard project.provider == provider else {
            throw AgentClientError.providerMismatch
        }
        return conversations
            .filter { $0.provider == provider && $0.kind == .project && $0.projectId == projectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func history(
        provider: ProviderId, conversationId: String, cursor: String?, limit: Int
    ) async throws -> HistoryPage {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw AgentClientError.notFound("conversation:\(conversationId)")
        }
        guard conversation.provider == provider else { throw AgentClientError.providerMismatch }
        if historyDelay > .zero { try? await Task.sleep(for: historyDelay) }

        // The newest page first, then the page before it. The cursor names the
        // oldest event already delivered, so it is read as an upper bound —
        // ignoring it, as this mock used to, replays the same page forever.
        //
        // The page size is the agent's to choose, not the caller's: the real
        // one serves five turns and ignores `limit`. Honouring `limit` here
        // let a test ask for the whole transcript at once and never exercise
        // paging at all.
        _ = limit
        let all = history[conversationId] ?? []
        let end = cursor.flatMap { cursor in
            all.firstIndex { $0.messageId == cursor }
        } ?? all.count
        let start = end > Self.historyPageEvents ? end - Self.historyPageEvents : 0
        return HistoryPage(
            events: Array(all[start..<end]),
            hasMore: start > 0,
            nextCursor: start > 0 ? all[start].messageId : nil
        )
    }

    public func startConversation(
        provider: ProviderId, kind: ConversationKind, cwd: String?
    ) async throws -> ConversationSummary {
        if kind == .project, cwd == nil {
            throw AgentClientError.invalidRequest("project_requires_cwd")
        }
        if kind == .daily, cwd != nil {
            throw AgentClientError.invalidRequest("daily_must_not_bind_project")
        }

        let projectId = cwd.map { "\(provider.rawValue):\($0)" }
        if let projectId, !projects.contains(where: { $0.id == projectId }) {
            throw AgentClientError.notFound("project:\(projectId)")
        }

        let summary = ConversationSummary(
            id: "\(provider.rawValue)-new-\(conversations.count + 1)",
            provider: provider,
            kind: kind,
            title: "New \(provider.displayName) session",
            projectId: projectId,
            projectPath: cwd,
            updatedAt: Date(timeIntervalSince1970: 1_788_000_000),
            status: .idle
        )
        conversations.append(summary)
        emit(
            .started(ConversationStarted(conversation: summary)),
            rawType: "conversation.started",
            conversationId: summary.id
        )
        return summary
    }

    public func resumeConversation(provider: ProviderId, conversationId: String) async throws {
        _ = try requireConversation(provider: provider, conversationId: conversationId)
    }

    public func send(provider: ProviderId, conversationId: String, text: String) async throws {
        let conversation = try requireConversation(
            provider: provider, conversationId: conversationId
        )
        if conversation.writeState == .busy {
            throw AgentClientError.rejected(conversation.writeBlockCode ?? "session_busy")
        }
        if text.lowercased().contains("fail"),
            scriptedFailures.insert(conversationId).inserted
        {
            throw AgentClientError.transport("send_failed")
        }
        let turnId = "turn-\(sequence + 1)"
        activeTurns[conversationId] = turnId

        emit(
            .userMessage(
                MessagePayload(messageId: "user-\(sequence + 1)", role: .user, text: text)
            ),
            rawType: "conversation.user_message",
            conversationId: conversationId
        )

        let assistantId = "assistant-\(sequence + 1)"
        let lowered = text.lowercased()
        let reply = "Working on \(conversation.title)."
        for fragment in MockAgentClient.split(reply) {
            emit(
                .delta(MessagePayload(messageId: assistantId, role: .assistant, text: fragment)),
                rawType: "conversation.delta",
                conversationId: conversationId
            )
        }

        if lowered.contains("approval") {
            let request = ApprovalRequest(
                id: "approval-\(sequence + 1)",
                provider: provider,
                conversationId: conversationId,
                category: .command,
                title: "Run a shell command",
                detail: "rm -rf build/",
                cwd: conversation.projectPath,
                risk: .high,
                createdAt: Date(timeIntervalSince1970: 1_788_000_000)
            )
            pendingApprovals[request.id] = request
            emit(
                .approvalRequested(request),
                rawType: "approval.requested",
                conversationId: conversationId
            )
            return
        }

        if lowered.contains("long") {
            // Turn deliberately left open so it can be interrupted.
            return
        }

        completeTurn(conversationId: conversationId, assistantId: assistantId, text: reply)
    }

    public func interrupt(provider: ProviderId, conversationId: String) async throws {
        _ = try requireConversation(provider: provider, conversationId: conversationId)
        guard let turnId = activeTurns.removeValue(forKey: conversationId) else {
            throw AgentClientError.invalidRequest("no_active_turn")
        }
        emit(
            .turnInterrupted(TurnPayload(turnId: turnId)),
            rawType: "turn.interrupted",
            conversationId: conversationId
        )
    }

    public func decideApproval(id: String, decision: ApprovalDecision) async throws {
        guard let request = pendingApprovals.removeValue(forKey: id) else {
            throw AgentClientError.notFound("approval:\(id)")
        }
        emit(
            .approvalResolved(ApprovalResolution(id: id, decision: decision)),
            rawType: "approval.resolved",
            conversationId: request.conversationId
        )
        completeTurn(
            conversationId: request.conversationId,
            assistantId: "assistant-\(sequence + 1)",
            text: decision == .allowOnce ? "Command finished." : "Command was declined."
        )
    }

    public func initialDirectory() async throws -> DirectoryListing {
        try await listFiles(path: "/Users/dev", showHidden: false)
    }

    public func listFiles(path: String, showHidden: Bool) async throws -> DirectoryListing {
        let normalized = try MockAgentClient.normalize(path)
        guard let entries = directories[normalized] else {
            throw AgentClientError.notFound("path:\(normalized)")
        }
        let visible = showHidden ? entries : entries.filter { !$0.hidden }
        return DirectoryListing(
            path: normalized,
            parentPath: MockAgentClient.parent(of: normalized),
            entries: visible.sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.name < rhs.name }
                return lhs.kind == .directory
            }
        )
    }

    public func filePreview(path: String, maxBytes: Int) async throws -> FilePreview {
        let normalized = try MockAgentClient.normalize(path)
        guard let text = previews[normalized] else {
            throw AgentClientError.notFound("path:\(normalized)")
        }
        let bytes = Array(text.utf8)
        let truncated = bytes.count > maxBytes
        let slice = truncated ? Array(bytes[0..<maxBytes]) : bytes
        return FilePreview(
            path: normalized,
            text: String(decoding: slice, as: UTF8.self),
            byteCount: bytes.count,
            truncated: truncated
        )
    }

    public func createTransfer(_ request: TransferRequest) async throws -> TransferTicket {
        transferRequestCount += 1
        lastCreatedTransferRequest = request
        let directory = try MockAgentClient.normalize(request.remoteDirectory)
        guard request.name.contains("/") == false, request.name != "..", request.name != "." else {
            throw AgentClientError.rejected("invalid_name")
        }
        guard let entries = directories[directory] else {
            throw AgentClientError.notFound("path:\(directory)")
        }

        let intended = "\(directory)/\(request.name)"
        let existing = entries.first { $0.path == intended }
        let chunkSize = 64 * 1024
        let totalChunks = max(1, Int((request.byteCount + Int64(chunkSize) - 1) / Int64(chunkSize)))

        // Conflict handling applies to uploads onto the Mac only; a download
        // reads a file that is expected to already exist.
        if request.direction == .upload, let existing, request.conflictPolicy == nil {
            // No policy chosen: report the conflict and leave the destination alone.
            return TransferTicket(
                id: "ticket-\(tickets.count + 1)",
                destinationPath: intended,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                conflict: TransferConflict(
                    existingPath: existing.path, existingSize: existing.size
                )
            )
        }

        let destination: String
        if request.direction == .upload, existing != nil, request.conflictPolicy == .keepBoth {
            destination = MockAgentClient.uniquePath(for: intended, in: entries)
        } else {
            destination = intended
        }

        let ticket = TransferTicket(
            id: "ticket-\(tickets.count + 1)",
            destinationPath: destination,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            conflict: nil
        )
        tickets[ticket.id] = ticket
        return ticket
    }

    public func uploadChunk(transferId: String, index: Int, data: Data) async throws {
        transferRequestCount += 1
        guard tickets[transferId] != nil else {
            throw AgentClientError.notFound("transfer:\(transferId)")
        }
        uploadedChunks[transferId, default: [:]][index] = data
    }

    public func downloadChunk(transferId: String, index: Int) async throws -> Data {
        transferRequestCount += 1
        guard let ticket = tickets[transferId] else {
            throw AgentClientError.notFound("transfer:\(transferId)")
        }
        let text = previews[ticket.destinationPath] ?? ""
        return Data(text.utf8)
    }

    public func finishTransfer(transferId: String) async throws -> TransferReceipt {
        transferRequestCount += 1
        guard let ticket = tickets.removeValue(forKey: transferId) else {
            throw AgentClientError.notFound("transfer:\(transferId)")
        }
        let chunks = uploadedChunks.removeValue(forKey: transferId) ?? [:]
        let payload = chunks.sorted { $0.key < $1.key }.map(\.value).reduce(into: Data()) {
            $0.append($1)
        }
        let directory = MockAgentClient.parent(of: ticket.destinationPath) ?? "/"
        let name = String(ticket.destinationPath.split(separator: "/").last ?? "")
        var entries = directories[directory] ?? []
        entries.removeAll { $0.path == ticket.destinationPath }
        entries.append(
            FileEntry(
                path: ticket.destinationPath, name: name, kind: .file,
                size: Int64(payload.count),
                modifiedAt: Date(timeIntervalSince1970: 1_788_000_000)
            )
        )
        directories[directory] = entries
        return TransferReceipt(
            id: ticket.id,
            finalPath: ticket.destinationPath,
            sha256: MockAgentClient.checksum(payload)
        )
    }

    public func cancelTransfer(transferId: String) async throws {
        transferRequestCount += 1
        tickets.removeValue(forKey: transferId)
        uploadedChunks.removeValue(forKey: transferId)
    }

    // MARK: - Accounts
    //
    // Mirrors the agent's rules, which the accounts screen depends on: one
    // current account per provider, signing in replaces the current
    // credential, deleting a saved account does not sign out of it, and the
    // sign-in flow shows a link and wants a code back.

    /// The code the scripted sign-in accepts. Anything else is rejected the
    /// way a real one would be.
    public static let mockLoginCode = "123456"

    private struct MockLogin: Sendable {
        let sessionId: String
        let label: String?
        var output: String
        var awaitingInput: Bool
    }

    public func accounts(provider: ProviderId) async throws -> AccountsView {
        accountsView(provider)
    }

    public func saveAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        guard let login = providerLogins[provider], login.state == .loggedIn else {
            throw AgentClientError.rejected("nothing_signed_in")
        }
        var saved = savedAccounts[provider] ?? []
        saved.removeAll { $0.label == label }
        saved.append(
            AccountEntry(label: label, display: login.account, isCurrent: true)
        )
        savedAccounts[provider] = saved.map {
            AccountEntry(
                label: $0.label, display: $0.display, isCurrent: $0.label == label,
                hasCredential: $0.hasCredential
            )
        }
        return accountsView(provider)
    }

    public func deleteAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        savedAccounts[provider] = (savedAccounts[provider] ?? []).filter { $0.label != label }
        return accountsView(provider)
    }

    public func activateAccount(provider: ProviderId, label: String) async throws -> AccountsView {
        let saved = savedAccounts[provider] ?? []
        guard let wanted = saved.first(where: { $0.label == label }), wanted.hasCredential else {
            throw AgentClientError.rejected("account_credential_missing")
        }
        savedAccounts[provider] = saved.map {
            AccountEntry(
                label: $0.label, display: $0.display, isCurrent: $0.label == label,
                hasCredential: $0.hasCredential
            )
        }
        providerLogins[provider] = ProviderLogin(
            state: .loggedIn, account: wanted.display ?? wanted.label
        )
        return accountsView(provider)
    }

    public func logout(provider: ProviderId) async throws -> AccountsView {
        providerLogins[provider] = ProviderLogin(state: .loggedOut)
        savedAccounts[provider] = (savedAccounts[provider] ?? []).map {
            AccountEntry(
                label: $0.label, display: $0.display, isCurrent: false,
                hasCredential: $0.hasCredential
            )
        }
        return accountsView(provider)
    }

    public func startLogin(provider: ProviderId, label: String?) async throws -> LoginProgress {
        if let running = mockLogins[provider] {
            return progress(provider, running)
        }
        // Asked for explicitly: signing in replaces whatever is signed in, so
        // the sign-out happens first and is visible.
        _ = try await logout(provider: provider)
        let session = MockLogin(
            sessionId: "mock-login-\(provider.rawValue)",
            label: label,
            output: """
                Open this link in your browser and sign in
                https://auth.example.com/device
                Enter this one-time code: MOCK-CODE1
                Paste the code here:
                """,
            awaitingInput: true
        )
        mockLogins[provider] = session
        lastLoginMessages[provider] = nil
        return progress(provider, session)
    }

    public func loginProgress(provider: ProviderId) async throws -> LoginProgress? {
        mockLogins[provider].map { progress(provider, $0) }
    }

    public func sendLoginInput(
        provider: ProviderId, sessionId: String, text: String
    ) async throws {
        guard let session = mockLogins[provider], session.sessionId == sessionId else {
            throw AgentClientError.rejected("login_not_running")
        }
        mockLogins[provider] = nil
        let succeeded = text == Self.mockLoginCode
        lastLoginMessages[provider] = succeeded ? nil : "That code was rejected"
        if succeeded {
            providerLogins[provider] = ProviderLogin(
                state: .loggedIn, account: "mock@example.com", detail: "Mock org · team"
            )
            if let label = session.label {
                var saved = (savedAccounts[provider] ?? []).map {
                    AccountEntry(
                        label: $0.label, display: $0.display, isCurrent: false,
                        hasCredential: $0.hasCredential
                    )
                }
                saved.removeAll { $0.label == label }
                saved.append(
                    AccountEntry(label: label, display: "mock@example.com", isCurrent: true)
                )
                savedAccounts[provider] = saved
            }
        }
        _ = emit(
            .providerLoginCompleted(
                LoginOutcome(
                    sessionId: sessionId,
                    provider: provider,
                    succeeded: succeeded,
                    message: succeeded ? nil : "That code was rejected"
                )
            ),
            rawType: "provider.login.completed",
            // Login belongs to no conversation, so it gets a channel of its
            // own rather than landing in whichever one is open.
            conversationId: "login:\(provider.rawValue)"
        )
    }

    public func cancelLogin(provider: ProviderId, sessionId: String) async throws {
        if mockLogins[provider]?.sessionId == sessionId {
            mockLogins[provider] = nil
        }
    }

    private func accountsView(_ provider: ProviderId) -> AccountsView {
        AccountsView(
            provider: provider,
            accounts: (savedAccounts[provider] ?? []).sorted { $0.label < $1.label },
            login: providerLogins[provider] ?? ProviderLogin(state: .unknown),
            loginInProgress: mockLogins[provider] != nil,
            lastLoginMessage: lastLoginMessages[provider]
        )
    }

    private func progress(_ provider: ProviderId, _ session: MockLogin) -> LoginProgress {
        LoginProgress(
            sessionId: session.sessionId,
            provider: provider,
            output: session.output,
            verificationUrl: "https://auth.example.com/device",
            userCode: "MOCK-CODE1",
            awaitingInput: session.awaitingInput
        )
    }

    public func listAudit(limit: Int) async throws -> [AuditEntry] {
        Array(audit.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    public func diagnostics() async throws -> Diagnostics {
        Diagnostics(
            agentVersion: "0.1.0-mock",
            macOSVersion: "14.0",
            cloudflaredVersion: "2026.2.0",
            endpoint: "https://remoteai.example.com",
            tunnelHealthy: true,
            providers: try await providerStatus()
        )
    }

    public func revokeDevice() async throws {
        audit.append(
            AuditEntry(
                id: "audit-\(audit.count + 1)",
                timestamp: Date(timeIntervalSince1970: 1_788_000_000),
                action: "device.revoke", provider: nil, conversationId: nil,
                targetPath: nil, outcome: "ok"
            )
        )
    }

    // MARK: - Helpers

    private func requireConversation(
        provider: ProviderId, conversationId: String
    ) throws -> ConversationSummary {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            throw AgentClientError.notFound("conversation:\(conversationId)")
        }
        guard conversation.provider == provider else { throw AgentClientError.providerMismatch }
        return conversation
    }

    private func completeTurn(conversationId: String, assistantId: String, text: String) {
        emit(
            .messageCompleted(
                MessagePayload(messageId: assistantId, role: .assistant, text: text)
            ),
            rawType: "conversation.message_completed",
            conversationId: conversationId
        )
        let turnId = activeTurns.removeValue(forKey: conversationId) ?? "turn-\(sequence)"
        emit(
            .turnCompleted(TurnPayload(turnId: turnId)),
            rawType: "turn.completed",
            conversationId: conversationId
        )
    }

    private nonisolated static func split(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [text] }
        return words.enumerated().map { index, word in
            index == words.count - 1 ? word : word + " "
        }
    }

    /// Rejects anything that is not already an absolute, normalized path.
    /// The real agent performs the authoritative check; this mirrors it so the
    /// client is never the component that relaxes the rule.
    nonisolated static func normalize(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw AgentClientError.rejected("relative_path") }
        let components = path.split(separator: "/")
        guard !components.contains("..") else { throw AgentClientError.rejected("path_traversal") }
        guard !components.contains(".") else { throw AgentClientError.rejected("path_traversal") }
        let joined = "/" + components.joined(separator: "/")
        return joined == "/" ? "/" : joined
    }

    nonisolated static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    nonisolated static func uniquePath(for path: String, in entries: [FileEntry]) -> String {
        let taken = Set(entries.map(\.path))
        let name = String(path.split(separator: "/").last ?? "")
        let directory = parent(of: path) ?? "/"
        let base: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[name.startIndex..<dot])
            ext = String(name[dot...])
        } else {
            base = name
            ext = ""
        }
        var index = 2
        while true {
            let candidate = "\(directory)/\(base) \(index)\(ext)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    nonisolated static func checksum(_ data: Data) -> String {
        // Deterministic non-cryptographic stand-in; the real client hashes with
        // CryptoKit SHA-256 in TransferClient.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
