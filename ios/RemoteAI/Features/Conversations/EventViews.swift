import SwiftUI

@MainActor
struct MessageBubble: View {
    let item: MessageItem

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(item.text)
                    .textSelection(.enabled)
                if item.isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
    }

    private var alignment: HorizontalAlignment { item.role == .user ? .trailing : .leading }
    private var label: String {
        switch item.role {
        case .user: return "You"
        case .assistant: return "AI"
        case .system: return "System"
        case .unknown: return ""
        }
    }
    private var background: Color {
        item.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
    }
}

@MainActor
struct ToolRow: View {
    let item: ToolItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.footnote.weight(.medium))
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let status = item.status {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
struct ErrorRow: View {
    let item: ErrorItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message).font(.footnote)
                Text(item.code).font(.caption2).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("timeline-error")
    }
}
