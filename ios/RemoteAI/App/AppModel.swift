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

    /// Where the provider-scoped catalog read has got to.
    ///
    /// The agent re-indexes the provider on every catalog request — Codex goes
    /// out to its app-server for it — so the read is slow enough to see. Views
    /// must distinguish "still reading" from "this provider really has none",
    /// otherwise the empty-state text flashes before the rows arrive.
    public enum CatalogLoadState: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    public private(set) var catalogState: CatalogLoadState = .idle
    public private(set) var projectSessionsState: CatalogLoadState = .idle

    /// True until the current provider's catalog has actually been answered.
    public var isLoadingCatalog: Bool { catalogState == .idle || catalogState == .loading }

    /// Only report "no projects" once a read has finished.
    public var showsEmptyProjects: Bool { projects.isEmpty && !isLoadingCatalog }

    public var showsEmptyDailyConversations: Bool {
        dailyConversations.isEmpty && !isLoadingCatalog
    }

    public var isLoadingProjectSessions: Bool {
        projectSessionsState == .idle || projectSessionsState == .loading
    }

    public var showsEmptyProjectSessions: Bool {
        projectConversations.isEmpty && !isLoadingProjectSessions
    }

    public let client: AgentClient
    /// Turns held-button speech into text, when this launch has one. The
    /// composer hides voice input entirely without it.
    public var transcriber: SpeechTranscriber?
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

    /// Whether a read may be attempted at all.
    ///
    /// Narrower than `isOnline`, which gates *writing*: a connection that has
    /// just failed a read is `recovering`, which blocks sending but must still
    /// try the next read. Were reads gated on `isOnline` too, one failure
    /// would be permanent — nothing would ever discover that the Mac came
    /// back. `disconnected` and `connecting` mean there is no usable pairing
    /// yet, so nothing is attempted.
    private var canAttemptRead: Bool {
        switch connectionState {
        case .disconnected, .connecting: return false
        case .paired, .online, .recovering: return true
        }
    }

    /// Whether a failure means the Mac could not be reached, as opposed to the
    /// Mac answering with a refusal.
    ///
    /// The distinction is the whole point of the connection banner: Codex
    /// running out of quota is not a connection problem, and must not stop the
    /// phone sending to Claude.
    private static func isUnreachable(_ error: Error) -> Bool {
        switch error as? AgentClientError {
        case .transport, .offline, .notPaired: return true
        default: return false
        }
    }

    /// A request arrived and was answered, so the connection is live again.
    private func noteReachable() {
        if connectionState == .recovering { setConnectionState(.online) }
    }

    private func noteFailure(_ error: Error) {
        lastErrorMessage = "\(error)"
        // Demote from `online`, not from `paired`: a pairing that has never
        // connected is not recovering from anything.
        if Self.isUnreachable(error), connectionState == .online {
            setConnectionState(.recovering)
        }
    }

    public func isAvailable(_ provider: ProviderId) -> Bool {
        providerStatuses[provider]?.available ?? true
    }

    /// Why a provider is refusing everything, if it is.
    public func problem(for provider: ProviderId) -> ProviderProblem? {
        providerStatuses[provider]?.problem
    }

    /// Which account a provider is signed in as, when the Mac could tell.
    public func login(for provider: ProviderId) -> ProviderLogin? {
        providerStatuses[provider]?.login
    }

    /// Re-read provider status without reloading the whole catalog.
    ///
    /// Used after a turn fails: the Mac classifies a failure it recognises
    /// into a standing provider problem, and this is how that reaches the
    /// banner without waiting for the next catalog reload.
    public func refreshProviderStatuses() async {
        guard canAttemptRead else { return }
        do {
            let statuses = try await client.providerStatus()
            providerStatuses = Dictionary(
                uniqueKeysWithValues: statuses.map { ($0.provider, $0) }
            )
            noteReachable()
        } catch {
            noteFailure(error)
        }
    }

    /// Called on every change of `connectionState`, however it came about —
    /// this setter, or the app noticing for itself that a request did not
    /// arrive. `AppDependencies` hangs the other screens' read-only flags off
    /// it, so a connection this model demotes takes them with it.
    public var onConnectionStateChange: ((ConnectionState) -> Void)?

    public func setConnectionState(_ state: ConnectionState) {
        guard state != connectionState else { return }
        connectionState = state
        onConnectionStateChange?(state)
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
        // The new provider has not been read yet, so the lists are unknown
        // rather than empty.
        catalogState = .idle
        projectSessionsState = .idle
    }

    public func switchProvider(to provider: ProviderId) async {
        guard provider != selectedProvider else { return }
        prepareProviderSwitch(to: provider)
        await reloadCatalog()
    }

    // MARK: - Catalog

    public func reloadCatalog() async {
        guard canAttemptRead else {
            // The cache is a real answer, so the screen stops being busy.
            applyCachedSnapshot()
            catalogState = .loaded
            return
        }
        catalogState = .loading
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
            noteReachable()
            catalogState = .loaded
        } catch {
            noteFailure(error)
            applyCachedSnapshot()
            catalogState = .failed
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
        // A different project's sessions are unknown until this one is read.
        projectSessionsState = .idle
        projectConversations =
            (cache.snapshot(for: selectedProvider)?.projectConversations[project.id] ?? [])
            .filter { $0.provider == selectedProvider && $0.projectId == project.id }

        guard canAttemptRead else {
            projectSessionsState = .loaded
            return
        }
        await refreshSelectedProject()
    }

    public func refreshSelectedProject() async {
        guard let project = selectedProject, project.provider == selectedProvider else { return }
        guard canAttemptRead else {
            applyCachedSnapshot()
            projectSessionsState = .loaded
            return
        }
        projectSessionsState = .loading
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
            noteReachable()
            projectSessionsState = .loaded
        } catch {
            noteFailure(error)
            projectSessionsState = .failed
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
        case .turnFailed:
            // The failure itself belongs to the transcript, which is showing
            // it already. What this adds is the question the transcript
            // cannot answer: was that this turn, or the whole provider?
            Task { await refreshProviderStatuses() }
        case .turnCompleted:
            // A turn getting through is the Mac's evidence that a standing
            // problem is over, so the banner has to be re-read to clear.
            if providerStatuses[selectedProvider]?.problem != nil {
                Task { await refreshProviderStatuses() }
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
