import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum AppModelSuite {

    @MainActor
    static func makeModel(
        preferences: PreferencesStore = InMemoryPreferencesStore(),
        cache: CatalogCache = InMemoryCatalogCache(),
        client: MockAgentClient = MockAgentClient()
    ) -> AppModel {
        AppModel(client: client, preferences: preferences, cache: cache)
    }

    public static let suite = TestSuite(
        name: "AppModelSuite",
        cases: [
            TestCase("the first launch selects Codex") {
                let model = await makeModel()
                try expectEqual(await model.selectedProvider, .codex)
            },

            TestCase("the last selected provider is restored on the next launch") {
                let preferences = InMemoryPreferencesStore()
                let first = await makeModel(preferences: preferences)
                await first.prepareProviderSwitch(to: .claude)

                let second = await makeModel(preferences: preferences)
                try expectEqual(await second.selectedProvider, .claude)
            },

            TestCase("construction immediately restores the selected provider cache") {
                let preferences = InMemoryPreferencesStore(lastProvider: .claude)
                let cache = InMemoryCatalogCache()
                let cached = ConversationSummary(
                    id: "cached-claude",
                    provider: .claude,
                    kind: .daily,
                    title: "Cached before refresh",
                    updatedAt: Date(timeIntervalSince1970: 1_788_000_000),
                    status: .idle
                )
                cache.store(
                    CatalogSnapshot(
                        provider: .claude,
                        dailyConversations: [cached],
                        projects: []
                    )
                )

                let model = await makeModel(preferences: preferences, cache: cache)

                try expectEqual(await model.dailyConversations, [cached])
            },

            TestCase("catalog refresh preserves cached sessions for projects not opened") {
                let cache = InMemoryCatalogCache()
                let project = ProjectSummary(
                    id: "codex:/Users/dev/work/api",
                    provider: .codex,
                    canonicalPath: "/Users/dev/work/api",
                    displayPath: "~/work/api",
                    title: "api",
                    updatedAt: Date(timeIntervalSince1970: 1_788_000_000),
                    available: true
                )
                let cachedSession = ConversationSummary(
                    id: "cached-project-session",
                    provider: .codex,
                    kind: .project,
                    title: "Cached project session",
                    projectId: project.id,
                    projectPath: project.canonicalPath,
                    updatedAt: Date(timeIntervalSince1970: 1_788_000_000),
                    status: .idle
                )
                cache.store(
                    CatalogSnapshot(
                        provider: .codex,
                        dailyConversations: [],
                        projects: [project],
                        projectConversations: [project.id: [cachedSession]]
                    )
                )
                let model = await makeModel(cache: cache)
                await model.setConnectionState(.online)

                await model.reloadCatalog()
                await model.setConnectionState(.disconnected)
                await model.selectProject(project)

                try expectEqual(await model.projectConversations, [cachedSession])
            },

            TestCase("switching provider empties the visible lists before new data loads") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                try expectFalse(await model.dailyConversations.isEmpty)
                try expectFalse(await model.projects.isEmpty)

                await model.prepareProviderSwitch(to: .claude)
                try expectEqual(await model.selectedProvider, .claude)
                try expectTrue(await model.dailyConversations.isEmpty, "stale Codex chats must be gone")
                try expectTrue(await model.projects.isEmpty, "stale Codex projects must be gone")
                try expectNil(await model.selectedProject)
                try expectTrue(await model.projectConversations.isEmpty)
            },

            TestCase("after switching, nothing from the previous provider remains") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                let codexTitles = Set(await model.dailyConversations.map(\.title))

                await model.switchProvider(to: .claude)
                let claudeChats = await model.dailyConversations
                let claudeProjects = await model.projects

                try expectFalse(claudeChats.isEmpty)
                try expectTrue(claudeChats.allSatisfy { $0.provider == .claude })
                try expectTrue(claudeProjects.allSatisfy { $0.provider == .claude })
                try expectTrue(
                    Set(claudeChats.map(\.title)).isDisjoint(with: codexTitles),
                    "Codex titles must not survive the switch"
                )
            },

            TestCase("switching back and forth never merges the two catalogs") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                await model.switchProvider(to: .claude)
                await model.switchProvider(to: .codex)

                let chats = await model.dailyConversations
                let projects = await model.projects
                try expectTrue(chats.allSatisfy { $0.provider == .codex })
                try expectTrue(projects.allSatisfy { $0.provider == .codex })
            },

            TestCase("daily chats exclude project sessions and vice versa") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                try expectTrue(await model.dailyConversations.allSatisfy { $0.kind == .daily })

                let project = try expectNotNil(await model.projects.first)
                await model.selectProject(project)
                let sessions = await model.projectConversations
                try expectFalse(sessions.isEmpty)
                try expectTrue(sessions.allSatisfy { $0.kind == .project })
                try expectTrue(sessions.allSatisfy { $0.projectId == project.id })
            },

            TestCase("explicit project refresh stays within the selected provider and project") {
                let client = MockAgentClient()
                let model = await makeModel(client: client)
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                let project = try expectNotNil(await model.projects.first)
                await model.selectProject(project)

                await model.refreshSelectedProject()

                let sessions = await model.projectConversations
                try expectTrue(sessions.allSatisfy { $0.provider == project.provider })
                try expectTrue(sessions.allSatisfy { $0.projectId == project.id })
                try expectEqual(await client.transferRequestCount, 0)
            },

            TestCase("selecting a project is cleared when the provider changes") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                await model.selectProject(try expectNotNil(await model.projects.first))
                try expectNotNil(await model.selectedProject)

                await model.switchProvider(to: .claude)
                try expectNil(await model.selectedProject)
                try expectTrue(await model.projectConversations.isEmpty)
            },

            TestCase("an offline app serves the cache and refuses to start a session") {
                let cache = InMemoryCatalogCache()
                let model = await makeModel(cache: cache)
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                let onlineChats = await model.dailyConversations

                let offline = await makeModel(cache: cache)
                await offline.setConnectionState(.disconnected)
                await offline.reloadCatalog()
                try expectEqual(await offline.dailyConversations, onlineChats, "cache is readable")

                let error = try await expectThrows {
                    _ = try await offline.startDailyConversation()
                }
                try expectEqual(error as? AgentClientError, .offline)
            },

            TestCase("switching provider while offline shows only the new provider's cache") {
                let cache = InMemoryCatalogCache()
                let warm = await makeModel(cache: cache)
                await warm.setConnectionState(.online)
                await warm.reloadCatalog()
                await warm.switchProvider(to: .claude)

                let offline = await makeModel(cache: cache)
                await offline.setConnectionState(.disconnected)
                await offline.reloadCatalog()
                try expectTrue(
                    await offline.dailyConversations.allSatisfy { $0.provider == .codex },
                    "an offline launch restores the Codex cache"
                )

                await offline.switchProvider(to: .claude)
                let chats = await offline.dailyConversations
                try expectFalse(chats.isEmpty, "the Claude cache is still readable offline")
                try expectTrue(
                    chats.allSatisfy { $0.provider == .claude },
                    "no Codex row may survive an offline switch"
                )
            },

            TestCase("an unsupported event is ignored and leaves the app usable") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                let before = await model.dailyConversations

                await model.handle(
                    EventEnvelope(
                        sequence: 1, conversationId: nil,
                        rawType: "conversation.telepathy",
                        event: .unsupported(rawType: "conversation.telepathy")
                    )
                )
                try expectEqual(await model.dailyConversations, before)
                try expectEqual(await model.connectionState, .online)
            },

            TestCase("a provider status change is applied without touching the other provider") {
                let model = await makeModel()
                await model.setConnectionState(.online)
                await model.reloadCatalog()

                await model.handle(
                    EventEnvelope(
                        sequence: 2, conversationId: nil,
                        rawType: "provider.status_changed",
                        event: .providerStatusChanged(
                            ProviderStatus(
                                provider: .claude, available: false, reason: "crashed"
                            )
                        )
                    )
                )
                try expectFalse(await model.isAvailable(.claude))
                try expectTrue(await model.isAvailable(.codex), "Codex must stay usable")
            },

            TestCase("replayed events are dropped so the UI never doubles a delta") {
                let model = await makeModel()
                let event = EventEnvelope(
                    sequence: 3, conversationId: "codex-daily-1",
                    rawType: "conversation.delta",
                    event: .delta(MessagePayload(messageId: "m", role: .assistant, text: "x"))
                )
                try expectTrue(await model.handle(event))
                try expectFalse(await model.handle(event), "replay must be dropped")
            },

            TestCase("browsing the whole app never issues a transfer request") {
                let client = MockAgentClient()
                let model = await makeModel(client: client)
                await model.setConnectionState(.online)
                await model.reloadCatalog()
                await model.selectProject(try expectNotNil(await model.projects.first))
                await model.switchProvider(to: .claude)
                await model.reloadCatalog()
                await model.selectProject(try expectNotNil(await model.projects.first))
                await model.switchProvider(to: .codex)

                try expectEqual(
                    await client.transferRequestCount, 0,
                    "the app must never transfer a file on its own"
                )
            },
            TestCase("a read that cannot reach the Mac stops claiming to be online") {
                // The banner said online for as long as an identity existed,
                // whatever the network was doing.
                let client = FailingCatalogClient(error: .transport("connection lost"))
                let model = await MainActor.run {
                    AppModel(
                        client: client,
                        preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }
                await MainActor.run { model.setConnectionState(.online) }

                await model.reloadCatalog()

                try expectEqual(
                    await model.connectionState, .recovering,
                    "a transport failure is the definition of not being online"
                )
                try expectFalse(
                    await model.isOnline, "sending into a dead connection cannot work"
                )
            },

            TestCase("a provider's own failure is not a connection failure") {
                // Codex running out of quota says nothing about whether the
                // Mac is reachable, and must not disable sending to Claude.
                let client = FailingCatalogClient(error: .rejected("provider_operation_failed"))
                let model = await MainActor.run {
                    AppModel(
                        client: client,
                        preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }
                await MainActor.run { model.setConnectionState(.online) }

                await model.reloadCatalog()

                try expectEqual(await model.connectionState, .online)
                try expectTrue(await model.isOnline)
            },

            TestCase("a recovering connection still tries the next read") {
                // Otherwise the first blip is permanent: the read path used to
                // return the cache without attempting anything.
                let client = RecoveringCatalogClient()
                let model = await MainActor.run {
                    AppModel(
                        client: client,
                        preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }
                await MainActor.run { model.setConnectionState(.online) }

                await model.reloadCatalog()
                try expectEqual(await model.connectionState, .recovering)

                await model.reloadCatalog()
                try expectEqual(
                    await model.connectionState, .online,
                    "the Mac came back, so the app must too"
                )
            },

            TestCase("an unpaired app never goes near the network") {
                let client = FailingCatalogClient(error: .transport("should not be called"))
                let model = await MainActor.run {
                    AppModel(
                        client: client,
                        preferences: InMemoryPreferencesStore(),
                        cache: InMemoryCatalogCache()
                    )
                }

                await model.reloadCatalog()

                try expectEqual(await model.connectionState, .disconnected)
                try expectEqual(await client.calls, 0)
            },

        ]
    )
}

/// A catalog read that always fails with one error.
private actor FailingCatalogClient: StubAgentClient {
    private let error: AgentClientError
    private(set) var calls = 0

    init(error: AgentClientError) { self.error = error }

    func providerStatus() async throws -> [ProviderStatus] {
        calls += 1
        throw error
    }
}

/// Fails once, then succeeds — a Mac that went away and came back.
private actor RecoveringCatalogClient: StubAgentClient {
    private var attempts = 0

    func providerStatus() async throws -> [ProviderStatus] {
        attempts += 1
        if attempts == 1 { throw AgentClientError.transport("connection lost") }
        return []
    }

    // The rest of the catalog read has to complete for the second attempt to
    // count as the Mac having come back.
    func listDailyConversations(provider: ProviderId) async throws -> [ConversationSummary] { [] }
    func listProjects(provider: ProviderId) async throws -> [ProjectSummary] { [] }
}
