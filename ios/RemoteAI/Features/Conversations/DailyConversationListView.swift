import SwiftUI

/// Daily chats for the selected AI only. Project sessions never appear here.
@MainActor
public struct DailyConversationListView: View {
    @State private var hasLoadedOnce = false
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
                if model.isLoadingCatalog {
                    LoadingRow(message: "Reading \(model.selectedProvider.displayName) chats…")
                        .accessibilityIdentifier("daily-loading")
                } else if model.showsEmptyDailyConversations {
                    Text("No \(model.selectedProvider.displayName) chats yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("daily-empty")
                }
                ForEach(model.dailyConversations) { conversation in
                    NavigationLink {
                        ConversationView(
                            conversation: conversation,
                            client: model.client,
                            isOnline: model.isOnline,
                            cache: model.transcriptCache
                        )
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .accessibilityIdentifier("daily-row-\(conversation.id)")
                }
            }
            .navigationTitle("\(model.selectedProvider.displayName) chats")
            .refreshable { await model.reloadCatalog() }
            // Same reason as ProjectDetailView: returning from a conversation
            // does not re-run `.task`, so the list would keep showing the row
            // this device inserted rather than the session the agent indexed.
            .onAppear {
                guard hasLoadedOnce else {
                    hasLoadedOnce = true
                    return
                }
                Task { await model.reloadCatalog() }
            }
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
                // Which front end recorded it. Most of what the phone lists
                // for a project was recorded by the terminal and so is not in
                // the desktop app at all; saying so makes that legible.
                if let source = conversation.source?.label {
                    Text(source)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .accessibilityIdentifier("conversation-source-\(conversation.id)")
                }
                if let path = conversation.workingPath ?? conversation.projectPath {
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
