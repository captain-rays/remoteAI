import SwiftUI

/// Projects for the selected AI only.
///
/// Codex and Claude keep separate project records even when they point at the
/// same folder, so a row here always belongs to exactly one provider.
@MainActor
public struct ProjectListView: View {
    @Bindable private var model: AppModel
    private let files: FileBrowserViewModel

    public init(model: AppModel, files: FileBrowserViewModel) {
        self.model = model
        self.files = files
    }

    public var body: some View {
        NavigationStack {
            List {
                if model.projects.isEmpty {
                    Text("No \(model.selectedProvider.displayName) projects yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("projects-empty")
                }
                ForEach(model.projects) { project in
                    NavigationLink {
                        ProjectDetailView(model: model, project: project, files: files)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.title)
                            Text(project.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if !project.available {
                                Text("Folder is missing on the Mac")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityIdentifier("project-row-\(project.id)")
                }
            }
            .navigationTitle("\(model.selectedProvider.displayName) projects")
            .refreshable { await model.reloadCatalog() }
        }
    }
}
