import SwiftUI

/// What is wrong with the provider itself, above whatever the reader is doing.
///
/// Separate from `ConnectionBanner` because the two answer different
/// questions and can be true at once: the Mac can be perfectly reachable
/// while Codex refuses every turn for want of credit. Placing it at the top
/// of the shell rather than inside a transcript reflects its scope — it
/// applies to every conversation of that provider.
@MainActor
public struct ProviderProblemBanner: View {
    private let provider: ProviderId
    private let problem: ProviderProblem?
    private let onSignIn: (() -> Void)?

    public init(
        provider: ProviderId,
        problem: ProviderProblem?,
        onSignIn: (() -> Void)? = nil
    ) {
        self.provider = provider
        self.problem = problem
        self.onSignIn = onSignIn
    }

    public var body: some View {
        if let problem {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: problem.code))
                    Text(problem.headline(for: provider))
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    if problem.needsLogin, let onSignIn {
                        Button("Sign in", action: onSignIn)
                            .font(.footnote)
                            .accessibilityIdentifier("provider-problem-sign-in")
                    }
                }
                // The provider's own words carry what the reader needs to act
                // on — the billing link, or the hour a limit resets — so they
                // are shown as given rather than summarised away.
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.18))
            .accessibilityIdentifier("provider-problem-banner")
            .accessibilityLabel(problem.headline(for: provider))
        }
    }

    private func symbol(for code: ProviderProblemCode) -> String {
        switch code {
        case .quotaExhausted: return "creditcard.trianglebadge.exclamationmark"
        case .rateLimited: return "hourglass"
        case .loginExpired: return "person.crop.circle.badge.exclamationmark"
        case .modelUnavailable: return "cpu"
        case .unknown: return "exclamationmark.triangle"
        }
    }
}
