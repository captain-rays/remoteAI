import SwiftUI
import UniformTypeIdentifiers

/// Browses the Mac filesystem and offers the two explicit transfer actions.
///
/// Every transfer here begins with a tap: "Upload a file…" opens the phone's
/// document picker, "Download" acts on the selected entry. Nothing runs from
/// `onAppear`, scene phase, or any background callback.
@MainActor
public struct FileBrowserView: View {
    @Bindable private var model: FileBrowserViewModel
    @Bindable private var transfers: TransferCoordinator
    @State private var isImporting = false
    @State private var isConfirmingReveal = false
    @State private var previewEntry: FileEntry?
    private let uploadFixture: UploadFixture?
    private let uiTestFileProbePath: String?

    public init(
        model: FileBrowserViewModel,
        transfers: TransferCoordinator,
        uploadFixture: UploadFixture? = nil,
        uiTestFileProbePath: String? = nil
    ) {
        self.model = model
        self.transfers = transfers
        self.uploadFixture = uploadFixture
        self.uiTestFileProbePath = uiTestFileProbePath
    }

    public var body: some View {
        NavigationStack {
            List {
                if let message = model.errorMessage {
                    Text(message)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("files-error")
                }

                if !model.favorites.isEmpty {
                    Section("Favourites") {
                        ForEach(model.favorites, id: \.self) { path in
                            Button(path) { Task { await model.open(path) } }
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }

                if !model.recentDirectories.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentDirectories, id: \.self) { path in
                            Button(path) { Task { await model.open(path) } }
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }

                Section(model.currentPath ?? "Mac") {
                    ForEach(model.visibleEntries) { entry in
                        entryRow(entry)
                    }
                }

                if !transfers.transfers.isEmpty {
                    Section("Transfers") {
                        ForEach(transfers.transfers) { transfer in
                            TransferRow(transfer: transfer) {
                                Task { await transfers.cancel(transfer.id) }
                            } onRetry: {
                                Task { await transfers.retry(transfer.id) }
                            } onResolveConflict: { policy in
                                Task { await transfers.resolvePendingConflict(policy) }
                            } onDiscardConflict: {
                                Task { await transfers.discardPendingConflict() }
                            }
                        }
                    }
                }
            }
            .searchable(text: $model.searchText)
            .navigationTitle("Files")
            .refreshable { await model.refresh() }
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                // Reached only after the user picked a file in the picker.
                handlePickedFile(result)
            }
            .confirmationDialog(
                "Show hidden and system folders?",
                isPresented: $isConfirmingReveal,
                titleVisibility: .visible
            ) {
                Button("Show them") {
                    Task { await model.revealSensitiveEntries(confirmed: true) }
                }
                .accessibilityIdentifier("reveal-hidden-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These folders can contain sensitive files.")
            }
            .sheet(item: $previewEntry) { entry in
                FilePreviewView(model: model, entry: entry)
            }
            .task { await model.loadInitialDirectory() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await model.openParent() }
            } label: {
                Label("Up", systemImage: "arrow.up.doc")
            }
            .disabled(model.listing?.parentPath == nil)

            Button {
                if model.showHidden {
                    Task { await model.hideSensitiveEntries() }
                } else {
                    isConfirmingReveal = true
                }
            } label: {
                Label("Hidden", systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .accessibilityIdentifier("toggle-hidden")

            Button {
                if let uploadFixture, let directory = model.currentPath {
                    // Tests still need an explicit tap, but do not depend on
                    // SpringBoard's external document-picker process.
                    beginUpload(
                        name: uploadFixture.name, data: uploadFixture.data, to: directory
                    )
                } else {
                    isImporting = true
                }
            } label: {
                Label("Upload a file…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.currentPath == nil || !transfers.isOnline)
            .accessibilityIdentifier("upload-button")

            if let uiTestFileProbePath {
                Button("Probe file boundary") {
                    Task { await model.open(uiTestFileProbePath) }
                }
                .accessibilityIdentifier("uitest-file-probe")
            }
        }
    }

    private func entryRow(_ entry: FileEntry) -> some View {
        HStack {
            Image(systemName: entry.kind == .directory ? "folder" : "doc")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                if entry.sensitive {
                    Text("sensitive").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if entry.kind == .directory {
                Button {
                    Task { await model.open(entry.path) }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityIdentifier("open-\(entry.name)")
            } else {
                Button("Preview") { previewEntry = entry }
                Button("Download") { startDownload(entry) }
                    .accessibilityIdentifier("download-\(entry.name)")
            }
        }
        .swipeActions {
            Button(model.isFavorite(entry.path) ? "Unfavourite" : "Favourite") {
                model.toggleFavorite(entry.path)
            }
        }
    }

    /// Called only from the `fileImporter` completion — i.e. after the user
    /// confirmed a file in the picker.
    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result,
            let url = urls.first,
            let directory = model.currentPath
        else { return }

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }

        beginUpload(name: url.lastPathComponent, data: data, to: directory)
    }

    private func beginUpload(name: String, data: Data, to directory: String) {
        Task {
            await transfers.startUpload(name: name, data: data, to: directory)
        }
    }

    /// Called only from the Download button.
    private func startDownload(_ entry: FileEntry) {
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(entry.name)
        Task { await transfers.startDownload(entry, to: destination) }
    }
}
