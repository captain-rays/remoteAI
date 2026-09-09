import SwiftUI

/// What is staged on the composer, above the text field.
///
/// One row per file, because the reader needs to see three things before
/// sending: which file, whether it has arrived, and how to get rid of it.
@MainActor
struct AttachmentChips: View {
    let items: [ComposerAttachments.Item]
    let onRemove: (UUID) -> Void
    let onRetry: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        icon(for: item.state)
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if case let .failed(reason) = item.state {
                            Button {
                                onRetry(item.id)
                            } label: {
                                Text("Retry").font(.caption2)
                            }
                            .accessibilityIdentifier("retry-attachment-\(item.name)")
                            .accessibilityHint(reason)
                        }
                        Button {
                            onRemove(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("remove-attachment-\(item.name)")
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityIdentifier("attachment-\(item.name)")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: 40)
    }

    @ViewBuilder
    private func icon(for state: ComposerAttachments.Item.State) -> some View {
        switch state {
        case let .uploading(fraction):
            // Determinate, because a 40 MB file over a phone connection is a
            // wait the reader should be able to judge.
            ProgressView(value: max(fraction, 0.02))
                .progressViewStyle(.circular)
                .frame(width: 12, height: 12)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
