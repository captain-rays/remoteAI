import SwiftUI

@MainActor
public struct ConversationView: View {
    @State private var model: ConversationViewModel
    @State private var draft = ""
    /// True once the transcript has been put at its newest end. The first
    /// layout has no rows yet, so the jump waits for them to arrive.
    @State private var hasOpenedAtNewest = false
    /// The row that was topmost when an earlier page was asked for, so the
    /// content can be pinned there instead of jumping once it is prepended.
    @State private var anchorAboveEarlierPage: String?
    @State private var isLoadingEarlier = false
    /// Whether the row that asks for earlier messages is on screen. It is
    /// state rather than a one-shot `onAppear` because the row can stay on
    /// screen across several pages — a short transcript keeps it in view until
    /// enough has been loaded to fill the screen.
    @State private var isEarlierRowOnScreen = false
    private let isOnline: Bool

    /// Marks the newest end of the transcript. It is a row of its own so the
    /// jump lands below the last message rather than on top of it.
    private static let newestAnchor = "transcript-newest"

    public init(
        conversation: ConversationSummary,
        client: AgentClient,
        isOnline: Bool,
        cache: CatalogCache? = nil
    ) {
        _model = State(
            initialValue: ConversationViewModel(
                conversation: conversation,
                client: client,
                cache: cache
            )
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    earlierHistoryRow
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
                    Color.clear
                        .frame(height: 1)
                        .id(Self.newestAnchor)
                }
                .padding()
            }
            .accessibilityIdentifier("transcript")
            .refreshable { await model.refreshHistory() }
            .onChange(of: model.items.count) { _, _ in
                settle(with: proxy)
            }
            .onAppear { settle(with: proxy) }
            // The row can already be on screen before the opening jump, and it
            // gets no second `onAppear` for staying there. Re-ask once the
            // transcript is positioned, and again after each page lands, so a
            // transcript shorter than the screen fills it instead of stopping
            // half-loaded.
            .onChange(of: hasOpenedAtNewest) { _, _ in loadEarlier() }
            .onChange(of: isLoadingEarlier) { _, loading in
                if !loading { loadEarlier() }
            }
        }
    }

    /// Sits above the transcript and asks for the page before it as soon as it
    /// is scrolled into view. It only exists while there is an earlier page,
    /// so reaching the start of the conversation ends the paging on its own.
    private var earlierHistoryRow: some View {
        Group {
            if model.hasMoreHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("earlier-history")
                .onAppear {
                    isEarlierRowOnScreen = true
                    loadEarlier()
                }
                .onDisappear { isEarlierRowOnScreen = false }
            }
        }
    }

    /// Put the transcript at its newest end on open, and keep it pinned to the
    /// row the user was reading when an earlier page arrives above it.
    private func settle(with proxy: ScrollViewProxy) {
        if let anchor = anchorAboveEarlierPage {
            anchorAboveEarlierPage = nil
            proxy.scrollTo(anchor, anchor: .top)
            return
        }
        guard !hasOpenedAtNewest, !model.items.isEmpty else { return }
        hasOpenedAtNewest = true
        proxy.scrollTo(Self.newestAnchor, anchor: .bottom)
    }

    private func loadEarlier() {
        // Wait for the opening jump: until it happens the row is on screen
        // simply because the transcript has not been positioned yet.
        guard hasOpenedAtNewest, isEarlierRowOnScreen, !isLoadingEarlier, model.hasMoreHistory
        else { return }
        isLoadingEarlier = true
        anchorAboveEarlierPage = model.items.first?.id
        Task {
            await model.loadMoreHistory()
            isLoadingEarlier = false
        }
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
