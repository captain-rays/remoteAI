import Foundation
import Observation

/// Root application state.
///
/// Every provider-scoped list on screen is produced here, filtered by the
/// selected provider *before* it reaches a view. Switching provider clears the
/// old lists first (`prepareProviderSwitch`) and only then loads the new ones,
/// so a merged catalog is not representable.
@MainActor
@Observable
public final class AppModel {
    public private(set) var selectedProvider: ProviderId
    public private(set) var providerStatuses: [ProviderId: ProviderStatus] = [:]
    public private(set) var dailyConversations: [ConversationSummary] = []
    public private(set) var projects: [ProjectSummary] = []
    public private(set) var selectedProject: ProjectSummary?
    public private(set) var projectConversations: [ConversationSummary] = []
    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var lastErrorMessage: String?

    public let client: AgentClient
    private let preferences: PreferencesStore
    private let cache: CatalogCache
    private var sequencer = EventSequencer()

    public init(client: AgentClient, preferences: PreferencesStore, cache: CatalogCache) {
        self.client = client
        self.preferences = preferences
        self.cache = cache
        // First launch defaults to Codex; afterwards the last choice wins.
        self.selectedProvider = preferences.lastProvider ?? .codex
        applyCachedSnapshot()
    }

    public var transcriptCache: CatalogCache { cache }

    public var isOnline: Bool { connectionState.allowsMutation }

    public func isAvailable(_ provider: ProviderId) -> Bool {
        providerStatuses[provider]?.available ?? true
    }

    public func setConnectionState(_ state: ConnectionState) {
        connectionState = state
    }

    // MARK: - Provider switching

    /// Drops every provider-scoped list. Called before loading another provider
    /// so stale rows are never visible next to new ones.
    public func prepareProviderSwitch(to provider: ProviderId) {
        selectedProvider = provider
        preferences.setLastProvider(provider)
        dailyConversations = []
        projects = []
        selectedProject = nil
        projectConversations = []
        lastErrorMessage = nil
    }

    public func switchProvider(to provider: ProviderId) async {
        guard provider != selectedProvider else { return }
        prepareProviderSwitch(to: provider)
        await reloadCatalog()
    }

    // MARK: - Catalog

    public func reloadCatalog() async {
        guard isOnline else {
            applyCachedSnapshot()
            return
        }
        do {
            let statuses = try await client.providerStatus()
            providerStatuses = Dictionary(
                uniqueKeysWithValues: statuses.map { ($0.provider, $0) }
            )

            let provider = selectedProvider
            let daily = try await client.listDailyConversations(provider: provider)
            let projectList = try await client.listProjects(provider: provider)

            // A late response for a provider the user already left must not land.
            guard provider == selectedProvider else { return }

            dailyConversations = daily.filter { $0.provider == provider && $0.kind == .daily }
            projects = projectList.filter { $0.provider == provider }
            cache.store(
                CatalogSnapshot(
                    provider: provider,
                    dailyConversations: dailyConversations,
                    projects: projects,
                    projectConversations:
                        cache.snapshot(for: provider)?.projectConversations ?? [:]
                )
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "\(error)"
            applyCachedSnapshot()
        }
    }

    private func applyCachedSnapshot() {
        let snapshot = cache.snapshot(for: selectedProvider) ?? .empty(selectedProvider)
        dailyConversations = snapshot.dailyConversations.filter { $0.provider == selectedProvider }
        projects = snapshot.projects.filter { $0.provider == selectedProvider }
        if let selectedProject {
            projectConversations =
                (snapshot.projectConversations[selectedProject.id] ?? [])
                .filter { $0.provider == selectedProvider }
        }
    }

    public func selectProject(_ project: ProjectSummary) async {
        guard project.provider == selectedProvider else {
            lastErrorMessage = "\(AgentClientError.providerMismatch)"
            return
        }
        selectedProject = project
        projectConversations =
            (cache.snapshot(for: selectedProvider)?.projectConversations[project.id] ?? [])
            .filter { $0.provider == selectedProvider && $0.projectId == project.id }

        guard isOnline else {
            return
        }
        await refreshSelectedProject()
    }

    public func refreshSelectedProject() async {
        guard let project = selectedProject, project.provider == selectedProvider else { return }
        guard isOnline else {
            applyCachedSnapshot()
            return
        }
        do {
            let sessions = try await client.listProjectConversations(
                provider: selectedProvider, projectId: project.id
            )
            guard selectedProject?.id == project.id else { return }
            projectConversations = sessions.filter {
                $0.provider == selectedProvider && $0.projectId == project.id
            }
            var snapshot =
                cache.snapshot(for: selectedProvider)
                ?? CatalogSnapshot(
                    provider: selectedProvider,
                    dailyConversations: dailyConversations,
                    projects: projects
                )
            var byProject = snapshot.projectConversations
            byProject[project.id] = projectConversations
            snapshot = CatalogSnapshot(
                provider: selectedProvider,
                dailyConversations: snapshot.dailyConversations,
                projects: snapshot.projects,
                projectConversations: byProject
            )
            cache.store(snapshot)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    public func clearSelectedProject() {
        selectedProject = nil
        projectConversations = []
    }

    // MARK: - Session creation

    public func startDailyConversation() async throws -> ConversationSummary {
        do {
            try requireOnline()
            let created = try await client.startConversation(
                provider: selectedProvider, kind: .daily, cwd: nil
            )
            dailyConversations.insert(created, at: 0)
            return created
        } catch {
            lastErrorMessage = Self.userMessage(for: error)
            throw error
        }
    }

    public func startProjectConversation(
        in project: ProjectSummary
    ) async throws -> ConversationSummary {
        do {
            try requireOnline()
            guard project.provider == selectedProvider else {
                throw AgentClientError.providerMismatch
            }
            let created = try await client.startConversation(
                provider: selectedProvider, kind: .project, cwd: project.canonicalPath
            )
            if selectedProject?.id == project.id {
                projectConversations.insert(created, at: 0)
            }
            return created
        } catch {
            lastErrorMessage = Self.userMessage(for: error)
            throw error
        }
    }

    private func requireOnline() throws {
        guard isOnline else { throw AgentClientError.offline }
    }

    public static func userMessage(for error: Error) -> String {
        switch error as? AgentClientError {
        case .offline: return "Mac is offline."
        case .notPaired: return "Pair with your Mac before starting a conversation."
        case .providerMismatch: return "That conversation belongs to another provider."
        case .notFound: return "The requested conversation was not found."
        case .rejected: return "The Mac rejected this request."
        case .invalidRequest: return "The request could not be sent."
        case .transport: return "The Mac could not be reached."
        case nil: return "The request failed."
        }
    }

    // MARK: - Events

    /// Applies one realtime event. Returns `false` when it was a duplicate or a
    /// replay and therefore ignored.
    @discardableResult
    public func handle(_ envelope: EventEnvelope) -> Bool {
        guard sequencer.accept(envelope) else { return false }

        switch envelope.event {
        case let .providerStatusChanged(status):
            providerStatuses[status.provider] = status
        case let .started(started):
            // The Rust agent reports only provider-native session facts, with
            // no summary to insert; the mock sends a full summary.
            if let conversation = started.conversation,
                conversation.provider == selectedProvider,
                conversation.kind == .daily,
                !dailyConversations.contains(where: { $0.id == conversation.id })
            {
                dailyConversations.insert(conversation, at: 0)
            }
        case .unsupported:
            // A schema addition must never disturb the app.
            break
        default:
            break
        }
        return true
    }
}
