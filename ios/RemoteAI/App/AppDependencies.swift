import CryptoKit
import Foundation
import Observation

public enum LaunchPairingStatus: String, Sendable, Hashable {
    case idle
    case requested
    case paired
    case failed
}

/// Builds the object graph for one launch.
///
/// `-UseMockAgent` selects the deterministic in-process agent, which is how the
/// UI tests run without the Rust agent or a network.
@MainActor
@Observable
public final class AppDependencies {
    nonisolated public static let defaultPublicOrigin = "http://127.0.0.1:8787"

    public let appModel: AppModel
    public let transfers: TransferCoordinator
    public let files: FileBrowserViewModel
    public let settings: SettingsViewModel
    public let pairing: PairingViewModel
    public let uploadFixture: UploadFixture?
    /// Opt-in UI-test hook for exercising the Agent's authoritative path boundary.
    /// Production launches never set this value.
    public let uiTestFileProbePath: String?
    public let publicOrigin: String
    /// The app model owns the connection state, because it is the only object
    /// that talks to the Mac often enough to know: a read that fails demotes
    /// it there. Mirroring it in a second stored property let the two drift,
    /// with the banner reading a value nothing had updated.
    public var connectionState: ConnectionState { appModel.connectionState }
    /// Explicit pairing bootstrap is a simulator/development flow. Its
    /// identity stays in-process so an unavailable simulator keychain cannot
    /// prevent the one-shot smoke from reaching the paired state.
    public let usesEphemeralPairingStore: Bool
    public private(set) var launchPairingStatus: LaunchPairingStatus = .idle
    private var didAttemptLaunchPairing = false
    private static var launchPairingTasks: [String: Task<Bool, Never>] = [:]

    public init(
        client: AgentClient,
        preferences: PreferencesStore,
        cache: CatalogCache,
        store: SecretStore,
        pairingService: PairingService,
        uploadFixture: UploadFixture? = nil,
        uiTestFileProbePath: String? = nil,
        publicOrigin: String = AppDependencies.defaultPublicOrigin,
        usesEphemeralPairingStore: Bool = false,
        transcriber: SpeechTranscriber? = nil
    ) {
        self.appModel = AppModel(client: client, preferences: preferences, cache: cache)
        self.transfers = TransferCoordinator(client: client)
        self.files = FileBrowserViewModel(client: client, preferences: preferences)
        self.settings = SettingsViewModel(client: client, cache: cache, store: store)
        self.pairing = PairingViewModel(
            store: store, registry: UsedSecretRegistry(), service: pairingService
        )
        self.uploadFixture = uploadFixture
        self.uiTestFileProbePath = uiTestFileProbePath
        self.publicOrigin = publicOrigin
        self.usesEphemeralPairingStore = usesEphemeralPairingStore

        appModel.onConnectionStateChange = { [weak self] state in
            self?.applyConnectivity(state)
        }
        appModel.transcriber = transcriber

        // A stored identity *is* a completed pairing. Starting disconnected
        // whenever this launch did not itself pair sent the reader back to the
        // QR screen after every reinstall and every Mac restart, even though
        // the credential was still in the keychain and the agent still knew
        // the device. If the Mac cannot be reached, the first request says so.
        if (try? store.load()) ?? nil != nil {
            // Through the setter, so the app model learns too: the banner
            // reads one and sending is gated on the other.
            setConnectionState(.online)
        }
    }

    public static func live(arguments: [String] = CommandLine.arguments) -> AppDependencies {
        let useMock = arguments.contains("-UseMockAgent")
        let publicOrigin = configuredPublicOrigin(arguments: arguments)
        let preferences: PreferencesStore =
            useMock ? InMemoryPreferencesStore() : UserDefaultsPreferencesStore()
        let cache: CatalogCache = useMock ? InMemoryCatalogCache() : FileCatalogCache()
        let explicitPairing = arguments.contains("-RemoteAIPairingPayload")
            || arguments.contains("-RemoteAIPairingFile")
        let store: SecretStore = useMock || explicitPairing
            ? InMemorySecretStore()
            : KeychainSecretStore()
        let uploadFixture = arguments.contains("-UITestMockDocumentPicker")
            ? UploadFixture(name: "README.md", data: Data("# UI test fixture\n".utf8))
            : nil
        let uiTestFileProbePath = argumentValue(
            named: "-UITestFileProbePath", arguments: arguments
        )

        // Lane B ships against the mock agent by design. Integration replaces
        // this with a WebSocket-backed AgentClient driven by
        // ConnectionCoordinator + CryptoBox; nothing else in the app changes.
        // `-SlowHistory` makes the mock answer a history read the way a real
        // Mac does — after a moment — so the transcript's behaviour when its
        // first page lands late is exercisable.
        let mock = MockAgentClient()
        if arguments.contains("-SlowHistory") {
            Task { await mock.setHistoryDelay(.milliseconds(1500)) }
        }
        let client: AgentClient = useMock
            ? mock
            : RemoteAgentClient(store: store)
        let pairingService: PairingService = useMock
            ? MockPairingService()
            : RemotePairingService()
        let dependencies = AppDependencies(
            client: client,
            preferences: preferences,
            cache: cache,
            store: store,
            pairingService: pairingService,
            uploadFixture: uploadFixture,
            uiTestFileProbePath: uiTestFileProbePath,
            publicOrigin: publicOrigin,
            usesEphemeralPairingStore: explicitPairing,
            // The mock launch recites a sentence instead of listening, so the
            // voice path is exercisable without a microphone or an account.
            transcriber: useMock ? MockTranscriber() : AliyunTranscriber(client: client)
        )
        dependencies.pairing.onPaired = { [weak dependencies] in
            dependencies?.setConnectionState(.online)
        }
        if useMock {
            // The in-process mock has no pairing handshake or network hop.
            // Keep production launches disconnected until an explicit pairing.
            dependencies.setConnectionState(.online)
        }
        return dependencies
    }

    /// Performs one explicit developer/simulator pairing bootstrap. The file
    /// is opt-in, bounded, and consumed only in memory; its contents are never
    /// logged or copied to app storage.
    public func bootstrapPairingIfRequested(arguments: [String] = CommandLine.arguments) async {
        guard !didAttemptLaunchPairing else { return }
        let didRequestPairing =
            arguments.contains("-RemoteAIPairingPayload")
            || arguments.contains("-RemoteAIPairingFile")
        let payload: String?
        if arguments.contains("-RemoteAIPairingPayload") {
            // An explicitly supplied (but malformed/oversized) inline value
            // must not fall back to a second source.
            payload = Self.pairingPayload(arguments: arguments)
        } else if let file = Self.pairingFileURL(arguments: arguments),
            let data = try? Data(contentsOf: file), data.count <= 64 * 1024
        {
            payload = String(data: data, encoding: .utf8)
        } else {
            payload = nil
        }
        guard let payload, !payload.isEmpty, payload.utf8.count <= 64 * 1024 else {
            // A launch that never asked to pair has not failed at anything;
            // only an explicit request with an unusable payload is a failure.
            launchPairingStatus = didRequestPairing ? .failed : .idle
            return
        }
        didAttemptLaunchPairing = true
        launchPairingStatus = .requested

        // SwiftUI may instantiate more than one root dependency object while
        // mounting the app. Share one in-flight result by payload digest so a
        // second instance cannot replay a one-time secret and overwrite a
        // successful state with HTTP 409.
        let digest = SHA256.hash(data: Data(payload.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let task: Task<Bool, Never>
        if let existing = Self.launchPairingTasks[key] {
            task = existing
        } else {
            let created = Task { @MainActor [weak self] in
                guard let self else { return false }
                await self.pairing.pair(scannedText: payload)
                return self.pairing.state == .paired
            }
            Self.launchPairingTasks[key] = created
            task = created
        }
        if await task.value {
            // Keep the launch path observable even if a view has not yet
            // subscribed to PairingViewModel's callback.
            setConnectionState(.online)
            launchPairingStatus = .paired
        } else {
            launchPairingStatus = .failed
        }
    }

    /// Returns an inline payload only when the flag has a non-option value and
    /// remains within the same bounded size as the file bootstrap.
    nonisolated public static func pairingPayload(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-RemoteAIPairingPayload"),
            arguments.indices.contains(arguments.index(after: index))
        else { return nil }
        let payload = arguments[arguments.index(after: index)]
        guard !payload.isEmpty, !payload.hasPrefix("-"), payload.utf8.count <= 64 * 1024 else {
            return nil
        }
        return payload
    }

    nonisolated public static func pairingFileURL(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-RemoteAIPairingFile"),
            arguments.indices.contains(arguments.index(after: index))
        else { return nil }
        let path = arguments[arguments.index(after: index)]
        guard !path.isEmpty, !path.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: path)
    }

    nonisolated private static func argumentValue(
        named name: String, arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: name),
            arguments.indices.contains(arguments.index(after: index))
        else { return nil }
        let value = arguments[arguments.index(after: index)]
        guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
        return value
    }

    /// Resolves a tunnel/agent origin without accepting credentials or a
    /// malformed URL. Launch arguments are useful for simulator smoke tests;
    /// the environment variable keeps production configuration out of source.
    public static func configuredPublicOrigin(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let argumentOrigin: String? = {
            guard let index = arguments.firstIndex(of: "-AgentPublicOrigin"),
                arguments.indices.contains(arguments.index(after: index))
            else { return nil }
            return arguments[arguments.index(after: index)]
        }()
        let candidate = argumentOrigin ?? environment["REMOTEAI_PUBLIC_ORIGIN"]
        guard let candidate,
            let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host != nil,
            url.user == nil,
            url.password == nil
        else { return defaultPublicOrigin }
        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Propagates connectivity to every screen that must go read-only offline.
    public func setConnectionState(_ state: ConnectionState) {
        appModel.setConnectionState(state)
        // Also directly, because the model only reports a *change*: setting
        // the state it already holds must still leave the screens consistent.
        applyConnectivity(state)
    }

    private func applyConnectivity(_ state: ConnectionState) {
        files.isOnline = state.allowsMutation
        transfers.isOnline = state.allowsMutation
    }
}
