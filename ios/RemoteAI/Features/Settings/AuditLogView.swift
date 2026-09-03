import SwiftUI

/// What this phone asked the Mac to do. Credentials are never recorded, so
/// there is nothing to redact here — only actions, targets and outcomes.
@MainActor
public struct AuditLogView: View {
    private let entries: [AuditEntry]

    public init(entries: [AuditEntry]) {
        self.entries = entries
    }

    @ViewBuilder
    public var body: some View {
        if entries.isEmpty {
            Text("Nothing recorded yet.").foregroundStyle(.secondary)
        } else {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.action).font(.footnote.weight(.medium))
                        Spacer()
                        Text(entry.outcome).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(entry.timestamp, style: .date)
                        Text(entry.timestamp, style: .time)
                        if let provider = entry.provider {
                            Text(provider.displayName)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if let path = entry.targetPath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .accessibilityIdentifier("audit-row-\(entry.id)")
            }
        }
    }
}
