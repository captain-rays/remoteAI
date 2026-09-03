import SwiftUI

/// Presents one AI permission request.
///
/// v1 offers exactly "Allow once" and "Deny"; there is no permanent allow and
/// no way to bypass the provider's own permission system.
@MainActor
public struct ApprovalCard: View {
    private let request: ApprovalRequest
    private let decisions: [ApprovalDecision]
    private let onDecide: (ApprovalDecision) -> Void

    public init(
        request: ApprovalRequest,
        decisions: [ApprovalDecision],
        onDecide: @escaping (ApprovalDecision) -> Void
    ) {
        self.request = request
        self.decisions = decisions
        self.onDecide = onDecide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(request.title, systemImage: "hand.raised")
                    .font(.headline)
                Spacer()
                if let risk = request.risk, risk != .unknown {
                    Text(risk.rawValue.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(risk == .high ? Color.red.opacity(0.2) : Color.yellow.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            Text(request.provider.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(request.detail)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)

            if let cwd = request.cwd {
                Text(cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            HStack {
                ForEach(decisions, id: \.self) { decision in
                    Button(role: decision == .deny ? .destructive : nil) {
                        onDecide(decision)
                    } label: {
                        Text(decision == .allowOnce ? "Allow once" : "Deny")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approval-\(decision.rawValue)")
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("approval-card")
    }
}
