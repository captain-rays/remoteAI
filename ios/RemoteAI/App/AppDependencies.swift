import Foundation

/// Builds the object graph for one launch.
///
/// `-UseMockAgent` selects the deterministic in-process agent, which is how the
/// UI tests run without the Rust agent or a network.
@MainActor
public final class AppDependencies {
    public let appModel: AppModel
    public let transfers: TransferCoordinator
    public let files: FileBrowserViewModel
    public let settings: SettingsViewModel
    public let pairing: PairingViewModel
    public let uploadFixture: UploadFixture?

    public init(
        client: AgentClient,
        preferences: PreferencesStore,
        cache: CatalogCache,
        store: SecretStore,
        pairingService: PairingService,
        uploadFixture: UploadFixture? = nil
    ) {
        self.appModel = AppModel(client: client, preferences: preferences, cache: cache)
        self.transfers = TransferCoordinator(client: client)
        self.files = FileBrowserViewModel(client: client, preferences: preferences)
        self.settings = SettingsViewModel(client: client, cache: cache, store: store)
        self.pairing = PairingViewModel(
            store: store, registry: UsedSecretRegistry(), service: pairingService
        )
        self.uploadFixture = uploadFixture
    }

    public static func live(arguments: [String] = CommandLine.arguments) -> AppDependencies {
        let useMock = arguments.contains("-UseMockAgent")
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
        return AppDependencies(
            client: MockAgentClient(),
            preferences: preferences,
            cache: cache,
            store: store,
            pairingService: MockPairingService(),
            uploadFixture: uploadFixture
        )
    }

    /// Propagates connectivity to every screen that must go read-only offline.
    public func setConnectionState(_ state: ConnectionState) {
        appModel.setConnectionState(state)
        files.isOnline = state.allowsMutation
        transfers.isOnline = state.allowsMutation
    }
}
