import SwiftUI

/// Read-only preview of a Mac file. The bytes are never written to the phone's
/// cache — downloading is a separate, explicit action.
@MainActor
public struct FilePreviewView: View {
    @Bindable private var model: FileBrowserViewModel
    private let entry: FileEntry

    public init(model: FileBrowserViewModel, entry: FileEntry) {
        self.model = model
        self.entry = entry
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                if let preview = model.preview, let text = preview.text {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                    if preview.truncated {
                        Text("Preview truncated — \(preview.byteCount) bytes total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No preview available for this file.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .navigationTitle(entry.name)
            .task { await model.loadPreview(entry) }
            .onDisappear { model.clearPreview() }
        }
        .accessibilityIdentifier("file-preview")
    }
}
