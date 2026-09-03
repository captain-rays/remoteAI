import SwiftUI

/// Explains the current connection state and, when offline, that the phone is
/// showing cached content only.
@MainActor
public struct ConnectionBanner: View {
    private let state: ConnectionState

    public init(state: ConnectionState) {
        self.state = state
    }

    public var body: some View {
        if state != .online {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(message)
                    .font(.footnote)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(background)
            .accessibilityIdentifier("connection-banner")
        }
    }

    private var symbol: String {
        switch state {
        case .online: return "checkmark.circle"
        case .recovering, .connecting: return "arrow.triangle.2.circlepath"
        case .paired: return "link"
        case .disconnected: return "wifi.slash"
        }
    }

    private var message: String {
        switch state {
        case .online: return "Connected"
        case .connecting: return "Connecting to your Mac…"
        case .recovering: return "Reconnecting — showing cached content"
        case .paired: return "Paired. Not connected yet."
        case .disconnected: return "Offline — cached content only, read-only"
        }
    }

    private var background: Color {
        state == .disconnected ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.12)
    }
}
