import SwiftUI

@MainActor
public struct ConversationView: View {
    @State private var model: ConversationViewModel
    @State private var draft = ""
    private let isOnline: Bool

    public init(conversation: ConversationSummary, client: AgentClient, isOnline: Bool) {
        _model = State(
            initialValue: ConversationViewModel(conversation: conversation, client: client)
        )
        self.isOnline = isOnline
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let approval = model.pendingApproval {
                ApprovalCard(request: approval, decisions: model.availableDecisions) { decision in
                    Task { await model.decide(decision) }
                }
                .padding(.horizontal)
            }
            composer
        }
        .navigationTitle(model.conversation.title)
        .task {
            model.isOnline = isOnline
            await model.loadHistory()
        }
        .task {
            // Subscribe independently so a send cannot race the history load
            // and publish events before the realtime consumer is attached.
            await consumeEvents()
        }
        .onChange(of: isOnline) { _, newValue in model.isOnline = newValue }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.conversation.provider.displayName)
                .font(.caption.weight(.semibold))
            if let path = model.conversation.projectPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text("Daily chat").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.canStop {
                Button(role: .destructive) {
                    Task { await model.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .accessibilityIdentifier("stop-turn")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.items) { item in
                    switch item {
                    case let .message(message):
                        MessageBubble(item: message)
                    case let .reasoning(reasoning):
                        ReasoningRow(item: reasoning)
                    case let .tool(tool):
                        ToolRow(item: tool)
                    case let .error(error):
                        ErrorRow(item: error)
                    case .approval:
                        EmptyView()
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("transcript")
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if model.canRetry {
                HStack {
                    Text("Message not sent.").font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.retryFailedSend() } }
                        .accessibilityIdentifier("retry-send")
                }
            }
            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("composer")
                Button {
                    let text = draft
                    draft = ""
                    Task { await model.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.isOnline)
                .accessibilityIdentifier("send")
            }
        }
        .padding()
    }

    /// Realtime fan-out for this screen. Events only ever mutate the transcript.
    private func consumeEvents() async {
        for await envelope in await model.eventStream() {
            model.handle(envelope)
        }
    }
}
