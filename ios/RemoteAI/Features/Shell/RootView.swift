import SwiftUI

@MainActor
public struct RootView: View {
    private let dependencies: AppDependencies
    @Bindable private var model: AppModel
    @State private var selectedTab = Tab.chat

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
            ConnectionBanner(state: model.connectionState)
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
                    uploadFixture: dependencies.uploadFixture
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
        .task {
            await dependencies.bootstrapPairingIfRequested()
            // Loading the catalog is the only thing that happens on launch.
            // No transfer is started here or anywhere else automatically.
            await model.reloadCatalog()
        }
    }
}
