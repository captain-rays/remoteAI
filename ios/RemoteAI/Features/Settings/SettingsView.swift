import SwiftUI

@MainActor
public struct SettingsView: View {
    @Bindable private var settings: SettingsViewModel
    @Bindable private var pairing: PairingViewModel
    @Bindable private var appModel: AppModel
    @State private var isPairing = false
    @State private var isConfirmingRevoke = false

    public init(settings: SettingsViewModel, pairing: PairingViewModel, appModel: AppModel) {
        self.settings = settings
        self.pairing = pairing
        self.appModel = appModel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("State", value: appModel.connectionState.rawValue)
                    Button("Pair with a Mac…") { isPairing = true }
                        .accessibilityIdentifier("start-pairing")
                    if case let .failed(message) = pairing.state {
                        Text(message).foregroundStyle(.orange)
                            .accessibilityIdentifier("pairing-error")
                    }
                }

                Section("Diagnostics") {
                    DiagnosticsView(diagnostics: settings.diagnostics)
                }

                Section("Cache") {
                    Text("The phone keeps only conversation and folder listings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear cached lists") {
                        Task { await settings.clearCache() }
                    }
                    .accessibilityIdentifier("clear-cache")
                }

                Section("Activity") {
                    AuditLogView(entries: settings.auditEntries)
                }

                Section {
                    Button("Revoke this phone", role: .destructive) {
                        isConfirmingRevoke = true
                    }
                    .accessibilityIdentifier("revoke-device")
                } footer: {
                    Text("This phone will lose access until you pair it again.")
                }
            }
            .navigationTitle("Settings")
            .task { await settings.reload() }
            .sheet(isPresented: $isPairing) {
                PairingScannerView(model: pairing)
            }
            .confirmationDialog(
                "Revoke this phone?",
                isPresented: $isConfirmingRevoke,
                titleVisibility: .visible
            ) {
                Button("Revoke", role: .destructive) {
                    Task {
                        await settings.revokeDevice(confirmed: true)
                        await pairing.revoke()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
