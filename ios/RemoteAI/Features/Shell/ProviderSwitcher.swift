import SwiftUI

/// The always-visible `Codex | Claude` switch.
///
/// Selecting a provider hands control to `AppModel.switchProvider`, which
/// clears the previous provider's rows before loading the new ones.
@MainActor
public struct ProviderSwitcher: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Picker("AI", selection: providerBinding) {
            ForEach(ProviderId.allCases, id: \.self) { provider in
                Text(provider.displayName)
                    .accessibilityIdentifier("provider-option-\(provider.rawValue)")
                    .tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("provider-switcher")
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var providerBinding: Binding<ProviderId> {
        Binding(
            get: { model.selectedProvider },
            set: { provider in
                Task { await model.switchProvider(to: provider) }
            }
        )
    }
}
