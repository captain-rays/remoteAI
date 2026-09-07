import SwiftUI

@MainActor
public struct RootView: View {
    @Bindable private var dependencies: AppDependencies
    @Bindable private var model: AppModel
    @State private var selectedTab = Tab.chat
    @State private var signingInTo: ProviderId?

    enum Tab: Hashable {
        case chat, projects, files, settings
    }

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.model = dependencies.appModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            ProviderSwitcher(model: model)
            ConnectionBanner(state: dependencies.connectionState)
            // A reachable Mac whose provider refuses every turn is a
            // different problem from an unreachable Mac, and both can be
            // true, so the two banners are independent.
            ProviderProblemBanner(
                provider: model.selectedProvider,
                problem: model.problem(for: model.selectedProvider),
                // An expired login is the one provider problem the phone can
                // actually fix, so the banner opens the screen that fixes it
                // rather than leaving the reader to find it.
                onSignIn: { signingInTo = model.selectedProvider }
            )
            Text("Connection: \(dependencies.connectionState.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("connection-state")
            if dependencies.launchPairingStatus != .idle {
                Text("Pairing bootstrap: \(dependencies.launchPairingStatus.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("launch-pairing-status")
            }
            Divider()

            TabView(selection: $selectedTab) {
                DailyConversationListView(model: model)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.chat)

                ProjectListView(model: model, files: dependencies.files)
                    .tabItem { Label("Projects", systemImage: "folder.badge.gearshape") }
                    .tag(Tab.projects)

                FileBrowserView(
                    model: dependencies.files,
                    transfers: dependencies.transfers,
                    uploadFixture: dependencies.uploadFixture,
                    uiTestFileProbePath: dependencies.uiTestFileProbePath
                )
                    .tabItem { Label("Files", systemImage: "externaldrive") }
                    .tag(Tab.files)

                SettingsView(
                    settings: dependencies.settings,
                    pairing: dependencies.pairing,
                    appModel: model
                )
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            }
        }
        .sheet(item: $signingInTo) { provider in
            NavigationStack {
                ProviderAccountsView(
                    model: AccountsViewModel(provider: provider, client: model.client)
                )
            }
        }
        .task {
            await dependencies.bootstrapPairingIfRequested()
            // Loading the catalog is the only thing that happens on launch.
            // No transfer is started here or anywhere else automatically.
            await model.reloadCatalog()
        }
    }
}
