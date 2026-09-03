import SwiftUI

/// Daily chats for the selected AI only. Project sessions never appear here.
@MainActor
public struct DailyConversationListView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            List {
                if let error = model.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("conversation-start-error")
                }
                if model.dailyConversations.isEmpty {
                    Text("No \(model.selectedProvider.displayName) chats yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("daily-empty")
                }
                ForEach(model.dailyConversations) { conversation in
                    NavigationLink {
                        ConversationView(
                            conversation: conversation,
                            client: model.client,
                            isOnline: model.isOnline
                        )
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .accessibilityIdentifier("daily-row-\(conversation.id)")
                }
            }
            .navigationTitle("\(model.selectedProvider.displayName) chats")
            .refreshable { await model.reloadCatalog() }
            .toolbar {
                Button {
                    Task { _ = try? await model.startDailyConversation() }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .disabled(!model.isOnline)
                .accessibilityIdentifier("new-daily-chat")
            }
        }
    }
}

@MainActor
struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.body)
            HStack(spacing: 6) {
                Text(conversation.updatedAt, style: .date)
                if let path = conversation.projectPath {
                    Text(path).lineLimit(1).truncationMode(.head)
                }
                if conversation.status == .running {
                    Text("running")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
