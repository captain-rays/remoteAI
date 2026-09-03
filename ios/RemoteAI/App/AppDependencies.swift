import Foundation

/// Builds the object graph for one launch.
///
/// `-UseMockAgent` selects the deterministic in-process agent, which is how the
/// UI tests run without the Rust agent or a network.
@MainActor
public final class AppDependencies {
    nonisolated public static let defaultPublicOrigin = "http://127.0.0.1:8787"

    public let appModel: AppModel
    public let transfers: TransferCoordinator
    public let files: FileBrowserViewModel
    public let settings: SettingsViewModel
    public let pairing: PairingViewModel
    public let uploadFixture: UploadFixture?
    public let publicOrigin: String
    private var didAttemptLaunchPairing = false

    public init(
        client: AgentClient,
        preferences: PreferencesStore,
        cache: CatalogCache,
        store: SecretStore,
        pairingService: PairingService,
        uploadFixture: UploadFixture? = nil,
        publicOrigin: String = AppDependencies.defaultPublicOrigin
    ) {
        self.appModel = AppModel(client: client, preferences: preferences, cache: cache)
        self.transfers = TransferCoordinator(client: client)
        self.files = FileBrowserViewModel(client: client, preferences: preferences)
        self.settings = SettingsViewModel(client: client, cache: cache, store: store)
        self.pairing = PairingViewModel(
            store: store, registry: UsedSecretRegistry(), service: pairingService
        )
        self.uploadFixture = uploadFixture
        self.publicOrigin = publicOrigin
    }

    public static func live(arguments: [String] = CommandLine.arguments) -> AppDependencies {
        let useMock = arguments.contains("-UseMockAgent")
        let publicOrigin = configuredPublicOrigin(arguments: arguments)
        let preferences: PreferencesStore =
            useMock ? InMemoryPreferencesStore() : UserDefaultsPreferencesStore()
        let cache: CatalogCache = useMock ? InMemoryCatalogCache() : FileCatalogCache()
        let store: SecretStore = useMock ? InMemorySecretStore() : KeychainSecretStore()
        let uploadFixture = arguments.contains("-UITestMockDocumentPicker")
            ? UploadFixture(name: "README.md", data: Data("# UI test fixture\n".utf8))
            : nil

        // Lane B ships against the mock agent by design. Integration replaces
        // this with a WebSocket-backed AgentClient driven by
        // ConnectionCoordinator + CryptoBox; nothing else in the app changes.
        let client: AgentClient = useMock
            ? MockAgentClient()
            : RemoteAgentClient(store: store)
        let pairingService: PairingService = useMock
            ? MockPairingService()
            : RemotePairingService(origin: URL(string: publicOrigin)!)
        let dependencies = AppDependencies(
            client: client,
            preferences: preferences,
            cache: cache,
            store: store,
            pairingService: pairingService,
            uploadFixture: uploadFixture,
            publicOrigin: publicOrigin
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
        guard !didAttemptLaunchPairing, let file = Self.pairingFileURL(arguments: arguments) else {
            return
        }
        didAttemptLaunchPairing = true
        guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024,
            let payload = String(data: data, encoding: .utf8), !payload.isEmpty
        else { return }
        await pairing.pair(scannedText: payload)
    }

    nonisolated public static func pairingFileURL(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-RemoteAIPairingFile"),
            arguments.indices.contains(arguments.index(after: index))
        else { return nil }
        let path = arguments[arguments.index(after: index)]
        guard !path.isEmpty, !path.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: path)
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
        files.isOnline = state.allowsMutation
        transfers.isOnline = state.allowsMutation
    }
}
