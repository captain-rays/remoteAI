import SwiftUI

@MainActor
public struct DiagnosticsView: View {
    private let diagnostics: Diagnostics?

    public init(diagnostics: Diagnostics?) {
        self.diagnostics = diagnostics
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
            Text("Diagnostics are not available while offline.")
                .foregroundStyle(.secondary)
        }
    }
}
