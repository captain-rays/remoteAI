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
                if item.role == .assistant {
                    TranscriptRenderer(markdown: item.text)
                } else {
                    Text(item.text)
                        .textSelection(.enabled)
                }
                if item.isStreaming || item.deliveryState == .sending {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if item.deliveryState == .failed {
                Text("Not sent")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("message-delivery-failed")
            }
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
        .accessibilityIdentifier("\(item.role.rawValue)-message-\(item.id)")
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
struct ReasoningRow: View {
    let item: ReasoningItem
    @State private var isExpanded: Bool

    init(item: ReasoningItem) {
        self.item = item
        _isExpanded = State(initialValue: item.isExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TranscriptRenderer(markdown: item.text)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Label("Reasoning", systemImage: "brain")
                    .font(.footnote.weight(.medium))
                if item.isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("reasoning-disclosure-\(item.id)")
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
