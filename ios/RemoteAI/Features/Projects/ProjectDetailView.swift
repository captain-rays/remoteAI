import SwiftUI

/// Sessions belonging to one project of one provider, plus a shortcut into that
/// project's folder in the Files tab.
@MainActor
public struct ProjectDetailView: View {
    @State private var hasLoadedOnce = false
    @Bindable private var model: AppModel
    private let project: ProjectSummary
    private let files: FileBrowserViewModel

    public init(model: AppModel, project: ProjectSummary, files: FileBrowserViewModel) {
        self.model = model
        self.project = project
        self.files = files
    }

    public var body: some View {
        List {
            Section("Folder") {
                Text(project.canonicalPath)
                    .font(.system(.footnote, design: .monospaced))
                Button {
                    Task { await files.open(project.canonicalPath) }
                } label: {
                    Label("Browse this folder", systemImage: "folder")
                }
                .accessibilityIdentifier("browse-project-folder")
            }

            Section("\(project.provider.displayName) sessions") {
                if model.isLoadingProjectSessions {
                    LoadingRow(message: "Reading sessions…")
                        .accessibilityIdentifier("project-sessions-loading")
                } else if model.showsEmptyProjectSessions {
                    Text("No sessions in this project yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("project-sessions-empty")
                }
                ForEach(model.projectConversations) { conversation in
                    NavigationLink {
                        ConversationView(
                            conversation: conversation,
                            client: model.client,
                            isOnline: model.isOnline,
                            cache: model.transcriptCache,
                            transcriber: model.transcriber
                        )
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .accessibilityIdentifier("project-session-\(conversation.id)")
                }
            }
        }
        .navigationTitle(project.title)
        .refreshable { await model.refreshSelectedProject() }
        .toolbar {
            Button {
                Task { _ = try? await model.startProjectConversation(in: project) }
            } label: {
                Label("New session", systemImage: "square.and.pencil")
            }
            .disabled(!model.isOnline)
            .accessibilityIdentifier("new-project-session")
        }
        .task { await model.selectProject(project) }
        // Coming back from a session must re-read the project: the view stays
        // alive in the navigation stack, so `.task` does not run again and the
        // list would keep showing the placeholder row for a session the agent
        // has since indexed for real.
        .onAppear {
            guard hasLoadedOnce else {
                hasLoadedOnce = true
                return
            }
            Task { await model.refreshSelectedProject() }
        }
    }
}
