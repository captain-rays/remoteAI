import SwiftUI

@MainActor
public struct ConversationView: View {
    @State private var model: ConversationViewModel
    @State private var draft = ""
    /// Lets sending put the keyboard away: the reader's next act is reading
    /// the reply, and a keyboard covers half the transcript.
    @FocusState private var composerIsFocused: Bool
    /// True once the transcript has been put at its newest end. The first
    /// layout has no rows yet, so the jump waits for them to arrive.
    @State private var hasOpenedAtNewest = false
    /// The row that was topmost when an earlier page was asked for, so the
    /// content can be pinned there instead of jumping once it is prepended.
    @State private var anchorAboveEarlierPage: String?
    @State private var isLoadingEarlier = false
    /// Where the reader is in the transcript. Measured, because a row's
    /// `onAppear` cannot answer it: a one-point marker at the end never
    /// disappears, and a row rebuilt by a prepended page appears again.
    @State private var scroll = TranscriptScroll()
    /// True once the transcript has been measured resting at its newest end.
    /// Before that a measurement of zero offset only means the opening jump
    /// has not landed yet, which must not be read as "the reader scrolled up".
    @State private var hasSettledAtNewest = false
    /// Whether to keep the newest end in view as content arrives.
    ///
    /// It cannot be re-derived from the latest measurement at the moment a
    /// reply lands: growing the content moves the end away from the reader
    /// without the reader having moved at all, and reading that as "they
    /// scrolled up" leaves every reply below the fold. So it is only given up
    /// when the reader has moved a whole screen away from the end.
    @State private var isFollowingNewest = true
    @State private var isDictating = false
    /// Voice input, when this build has a transcriber. `nil` leaves the
    /// composer exactly as it was, so a Mac with no speech configured shows no
    /// button that cannot work.
    @State private var dictation: VoiceDictation?
    private let isOnline: Bool

    /// Marks the newest end of the transcript. It is a row of its own so the
    /// jump lands below the last message rather than on top of it.
    private static let newestAnchor = "transcript-newest"
    private static let scrollSpace = "transcript-scroll"

    public init(
        conversation: ConversationSummary,
        client: AgentClient,
        isOnline: Bool,
        cache: CatalogCache? = nil,
        transcriber: SpeechTranscriber? = nil
    ) {
        _model = State(
            initialValue: ConversationViewModel(
                conversation: conversation,
                client: client,
                cache: cache
            )
        )
        _dictation = State(initialValue: transcriber.map { VoiceDictation(transcriber: $0) })
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        earlierHistoryRow
                        if model.isLoadingHistory {
                            LoadingRow(message: "Loading this conversation…")
                                .accessibilityIdentifier("transcript-loading")
                        }
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
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: TranscriptScrollKey.self,
                                value: TranscriptScroll(
                                    offset: -content.frame(in: .named(Self.scrollSpace)).minY,
                                    contentHeight: content.size.height,
                                    viewportHeight: viewport.size.height
                                )
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .accessibilityIdentifier("transcript")
                .refreshable { await model.refreshHistory() }
                .onPreferenceChange(TranscriptScrollKey.self) { measured in
                    scroll = measured
                    if hasOpenedAtNewest, measured.isAtNewestEnd {
                        hasSettledAtNewest = true
                    }
                    if measured.isAtNewestEnd {
                        isFollowingNewest = true
                    } else if measured.hasLeftTheNewestEnd, model.hasLoadedHistoryOnce {
                        // Before the first page lands the content grows in one
                        // jump, which moves the newest end further away than a
                        // reader ever could. Giving up on following there is
                        // why a conversation opened part-way up the history.
                        isFollowingNewest = false
                    }
                    if measured.isNearOldestLoaded, !measured.isAtNewestEnd {
                        loadEarlier()
                    }
                }
                // A streamed reply grows an existing row rather than adding
                // one, so the row count alone would miss it.
                .onChange(of: newestRowFingerprint) { _, _ in
                    settle(with: proxy)
                }
                .onAppear { settle(with: proxy) }
            }
        }
    }

    /// Sits above the transcript while there is an earlier page, so reaching
    /// the start of the conversation ends the paging on its own.
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
            }
        }
    }

    /// Hand the draft to the provider and get out of the reader's way: the
    /// field empties and the keyboard closes, so the reply has the screen.
    private func submitDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        composerIsFocused = false
        Task { await model.send(text) }
    }

    /// What the newest end of the transcript looks like right now. It changes
    /// both when a row is added and when the last row's text grows, which is
    /// how a streamed reply arrives.
    private var newestRowFingerprint: String {
        guard case let .message(last)? = model.items.last else {
            return "\(model.items.count)"
        }
        return "\(model.items.count):\(last.text.count)"
    }

    /// Put the transcript at its newest end on open, follow it while the reader
    /// is there, and pin it to the row they were reading when an earlier page
    /// arrives above it.
    private func settle(with proxy: ScrollViewProxy) {
        guard !model.items.isEmpty else { return }
        let pinned = anchorAboveEarlierPage
        anchorAboveEarlierPage = nil

        // Only count the transcript as opened once its first page is in: an
        // empty or cached-only render would otherwise consume the one jump.
        guard hasOpenedAtNewest, model.hasLoadedHistoryOnce else {
            hasOpenedAtNewest = model.hasLoadedHistoryOnce
            proxy.scrollTo(Self.newestAnchor, anchor: .bottom)
            return
        }
        // Still following the newest end: stay there, whatever arrived.
        if isFollowingNewest {
            proxy.scrollTo(Self.newestAnchor, anchor: .bottom)
            return
        }
        // Reading further back is deliberate. Keep the row they were on where
        // it was, and never pull them to the bottom.
        if let pinned {
            proxy.scrollTo(pinned, anchor: .top)
        }
    }

    private func loadEarlier() {
        // A transcript that fits on one screen is both at its newest end and
        // at its oldest loaded turn, so it never asks for more. Five real
        // exchanges rarely fit, and pull-to-refresh still reaches the agent.
        guard hasSettledAtNewest, !isLoadingEarlier, model.hasMoreHistory else { return }
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
            if let dictation, case let .failed(reason) = dictation.state {
                HStack {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("OK") { dictation.acknowledgeFailure() }
                        .font(.caption)
                        .accessibilityIdentifier("dismiss-dictation-failure")
                }
                .accessibilityIdentifier("dictation-failure")
            }
            HStack(spacing: 8) {
                // Voice and keyboard are the same button: it is the mode the
                // reader is leaving that names it.
                if dictation != nil {
                    Button {
                        isDictating.toggle()
                        if isDictating {
                            composerIsFocused = false
                        }
                    } label: {
                        Image(systemName: isDictating ? "keyboard" : "mic")
                            .font(.title3)
                    }
                    .accessibilityIdentifier(isDictating ? "use-keyboard" : "use-voice")
                    .accessibilityLabel(isDictating ? "Use the keyboard" : "Use voice")
                }

                if isDictating, let dictation {
                    HoldToTalkButton(dictation: dictation, isOnline: model.isOnline)
                } else {
                    TextField("Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        // Three lines at rest rather than one: a dictated
                        // instruction is usually a sentence or two, and it is
                        // meant to be read back before it is sent.
                        .lineLimit(3...8)
                        .focused($composerIsFocused)
                        .accessibilityIdentifier("composer")
                    Button {
                        submitDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                    .disabled(
                        draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.isOnline
                    )
                    .accessibilityIdentifier("send")
                }
            }
        }
        .padding()
        // What was dictated lands in the composer, which switches back to the
        // keyboard so it can be read and corrected before it is sent. This
        // client drives Claude with permission prompts bypassed, so a misheard
        // instruction is one the Mac would carry out.
        .onChange(of: dictation?.finishedTranscript) { _, transcript in
            guard let transcript, let dictation else { return }
            guard let text = dictation.takeTranscript(), !text.isEmpty else { return }
            _ = transcript
            draft = draft.isEmpty ? text : draft + text
            isDictating = false
            composerIsFocused = true
        }
    }

    /// Realtime fan-out for this screen. Events only ever mutate the transcript.
    private func consumeEvents() async {
        for await envelope in await model.eventStream() {
            model.handle(envelope)
        }
    }
}

/// Where the reader is in a transcript, in points.
struct TranscriptScroll: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// Slack so a resting scroll view, which settles a fraction of a point
    /// away, still counts as parked at an edge.
    private static let slack: CGFloat = 24

    /// The reader is at the newest end, so a reply arriving should stay in
    /// view. A transcript shorter than the screen is always at its end.
    var isAtNewestEnd: Bool {
        guard contentHeight > 0 else { return true }
        if contentHeight <= viewportHeight + Self.slack { return true }
        return offset + viewportHeight >= contentHeight - Self.slack
    }

    /// The reader has reached the oldest turn loaded so far, which is the
    /// request for the page before it.
    var isNearOldestLoaded: Bool {
        contentHeight > 0 && offset <= Self.slack
    }

    /// The reader has moved a whole screen back from the newest end, which no
    /// amount of arriving content can do on its own.
    var hasLeftTheNewestEnd: Bool {
        guard contentHeight > viewportHeight else { return false }
        return contentHeight - (offset + viewportHeight) > viewportHeight
    }
}

private struct TranscriptScrollKey: PreferenceKey {
    static let defaultValue = TranscriptScroll()

    static func reduce(value: inout TranscriptScroll, nextValue: () -> TranscriptScroll) {
        let next = nextValue()
        // Only a real measurement replaces one; the default carries no size.
        if next.contentHeight > 0 { value = next }
    }
}
