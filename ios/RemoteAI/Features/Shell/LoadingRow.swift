import SwiftUI

/// Progress placeholder for a list that is still being read.
///
/// The agent re-indexes a provider on every catalog request, so these reads take
/// a visible moment. Without this the list shows its "nothing here" text while
/// the answer is in flight, which reads as "you have no projects".
@MainActor
public struct LoadingRow: View {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}
