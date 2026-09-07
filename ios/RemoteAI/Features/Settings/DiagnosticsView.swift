import SwiftUI

@MainActor
public struct DiagnosticsView: View {
    private let diagnostics: Diagnostics?
    /// Why the read did not produce anything, if it failed.
    private let failure: String?

    public init(diagnostics: Diagnostics?, failure: String? = nil) {
        self.diagnostics = diagnostics
        self.failure = failure
    }

    @ViewBuilder
    public var body: some View {
        if let diagnostics {
            LabeledContent("Agent", value: diagnostics.agentVersion)
            LabeledContent("macOS", value: diagnostics.macOSVersion)
            LabeledContent("cloudflared", value: diagnostics.cloudflaredVersion ?? "not found")
            LabeledContent("Endpoint", value: diagnostics.endpoint)
            LabeledContent("Tunnel", value: diagnostics.tunnelHealthy ? "healthy" : "down")
            ForEach(diagnostics.providers) { status in
                LabeledContent(status.provider.displayName) {
                    Text(
                        status.available
                            ? (status.version ?? "installed")
                            : (status.reason ?? "unavailable")
                    )
                    .foregroundStyle(status.available ? Color.primary : Color.orange)
                }
            }
            .accessibilityIdentifier("diagnostics")
        } else {
            // "Offline" was a guess: this reads the same whether the Mac was
            // unreachable, the request failed, or nothing has asked yet.
            // Saying which is the difference between an explanation and a
            // wrong explanation.
            Text(failure ?? "Diagnostics have not loaded yet.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("diagnostics-unavailable")
        }
    }
}
