import SwiftUI

/// Blocks a same-name upload until the user chooses. There is no default and
/// no "remember this" — the destination is untouched while this sheet is open.
@MainActor
public struct TransferConflictSheet: View {
    private let pending: PendingConflict
    private let onResolve: (ConflictPolicy) -> Void
    private let onCancel: () -> Void

    public init(
        pending: PendingConflict,
        onResolve: @escaping (ConflictPolicy) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pending = pending
        self.onResolve = onResolve
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A file with this name already exists")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(pending.conflict.existingPath)
                    .font(.system(.footnote, design: .monospaced))
                if let size = pending.conflict.existingSize {
                    Text("\(size) bytes on the Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Keep both") { onResolve(.keepBoth) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("conflict-keep-both")

            Button("Overwrite", role: .destructive) { onResolve(.overwrite) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("conflict-overwrite")

            Button("Cancel this upload", role: .cancel) { onCancel() }
                .accessibilityIdentifier("conflict-cancel")

            Spacer()
        }
        .padding()
        .accessibilityIdentifier("conflict-sheet")
    }
}

@MainActor
struct TransferRow: View {
    let transfer: TransferState
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onResolveConflict: (ConflictPolicy) -> Void
    let onDiscardConflict: () -> Void

    init(
        transfer: TransferState,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onResolveConflict: @escaping (ConflictPolicy) -> Void,
        onDiscardConflict: @escaping () -> Void
    ) {
        self.transfer = transfer
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onResolveConflict = onResolveConflict
        self.onDiscardConflict = onDiscardConflict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(
                    systemName: transfer.direction == .upload
                        ? "square.and.arrow.up" : "square.and.arrow.down"
                )
                Text(transfer.name)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            // A download's destination is a sandbox path nobody can act on;
            // name the place the Files app shows instead.
            Text(destinationText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityIdentifier("transfer-destination-\(transfer.id)")

            if transfer.status == .running {
                ProgressView(value: transfer.progress.fraction)
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("transfer-cancel")
            }
            if transfer.status == .awaitingDecision {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A file with this name already exists")
                        .font(.caption)
                    HStack {
                        Button("Keep both") { onResolveConflict(.keepBoth) }
                            .accessibilityIdentifier("conflict-keep-both")
                        Button("Overwrite", role: .destructive) {
                            onResolveConflict(.overwrite)
                        }
                        .accessibilityIdentifier("conflict-overwrite")
                        Button("Cancel", role: .cancel, action: onDiscardConflict)
                            .accessibilityIdentifier("conflict-cancel")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conflict-sheet")
            }
            if case .failed = transfer.status {
                Button("Retry", action: onRetry)
                    .accessibilityIdentifier("transfer-retry")
            }
            if let sha = transfer.sha256, transfer.status == .completed {
                Text("sha256 \(String(sha.prefix(16)))…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("transfer-\(transfer.id)")
    }

    private var destinationText: String {
        guard transfer.direction == .download else { return transfer.destinationPath }
        return TransferCoordinator.downloadLocationDescription(
            for: URL(fileURLWithPath: transfer.destinationPath)
        )
    }

    private var statusText: String {
        switch transfer.status {
        case .awaitingDecision: return "needs a decision"
        case .running: return "\(Int(transfer.progress.fraction * 100))%"
        case .completed: return "done"
        case .cancelled: return "cancelled"
        case let .failed(reason): return "failed — \(reason)"
        }
    }
}
