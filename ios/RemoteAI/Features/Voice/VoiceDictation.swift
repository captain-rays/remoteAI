import Foundation
import Observation
import SwiftUI

/// One dictation session, as the screen sees it.
public enum DictationState: Equatable, Sendable {
    case idle
    /// The button is held but the service has not opened yet.
    case opening
    /// Listening, with the transcript so far.
    case listening(String)
    /// Why it stopped. Shown next to the composer, not thrown away.
    case failed(String)
}

/// What went on underneath, for when the service produced no words.
///
/// "Nothing was heard" is true of three different faults — a service that was
/// never reached, a microphone that yielded nothing, and audio the service
/// made nothing of — and they need different things done about them. Reading
/// the same sentence for all three tells the person holding the phone nothing.
public struct DictationDiagnosis: Sendable, Equatable {
    /// How many audio frames reached the service. `nil` from a transcriber
    /// that keeps no account — which is not the same as zero, and saying "no
    /// sound reached the microphone" on that basis would be a guess.
    public var audioFramesSent: Int?
    /// The last error from sending audio, if any.
    public var lastAudioError: String?
    /// Converted buffers the connection could not keep up with. Recorded so
    /// a session that produced nothing can say audio was lost rather than
    /// blame a microphone that was working.
    public var droppedAudioFrames = 0
    /// Why the connection to the service never opened, in the system's own
    /// words. A blocked host does not produce an error at all — the packets
    /// are dropped and the socket simply waits — so "it did not answer" was
    /// all the app could say until this was recorded.
    public var connectionError: String?

    public init(
        audioFramesSent: Int? = nil, lastAudioError: String? = nil,
        connectionError: String? = nil, droppedAudioFrames: Int = 0
    ) {
        self.audioFramesSent = audioFramesSent
        self.lastAudioError = lastAudioError
        self.connectionError = connectionError
        self.droppedAudioFrames = droppedAudioFrames
    }
}

/// What a transcriber has to do, kept behind a protocol so the button's
/// behaviour can be tested without a microphone or a network.
public protocol SpeechTranscriber: Sendable {
    /// Open a session and start streaming the microphone. The stream ends when
    /// the service completes or fails.
    func start() async throws -> AsyncStream<SpeechProtocol.Event>
    /// Stop sending audio and let the service finish the sentence.
    func finish() async
    /// Abandon the session without waiting for a result.
    func cancel() async
    /// Where it got to, asked only when there is nothing to show for it.
    func diagnosis() async -> DictationDiagnosis
    /// Get whatever needs a person's answer out of the way — the microphone
    /// prompt — before the button is held.
    func prepare() async
}

extension SpeechTranscriber {
    /// A transcriber that keeps no account of itself — the scripted ones in
    /// tests — reports nothing rather than pretending.
    public func diagnosis() async -> DictationDiagnosis { DictationDiagnosis() }
    public func prepare() async {}
}

/// Hold-to-talk, and what it leaves in the composer.
///
/// The result is handed to the composer for review rather than sent: this
/// client drives Claude with permission prompts bypassed, and a misheard
/// instruction is one the Mac would carry out. Recognition of technical terms
/// is where it goes wrong — measured against this service, "remoteAICli"
/// came back as "remote ee" — which is exactly the sort of word this app's
/// messages are made of.
@MainActor
@Observable
public final class VoiceDictation {
    public private(set) var state: DictationState = .idle
    /// What the reader said, ready for the composer. Cleared once taken.
    public private(set) var finishedTranscript: String?

    private let transcriber: SpeechTranscriber
    private var sentences: [String] = []
    private var partial = ""
    /// Whether the service acknowledged this session.
    private var sawSessionOpen = false
    private var session: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// How long the service gets to produce a result after the button is
    /// released.
    ///
    /// It does not always answer: with no audio captured — a microphone that
    /// yielded nothing, a hold too short to produce a frame — the service has
    /// nothing to finish and says nothing at all. Waiting forever leaves the
    /// button reading "Listening…" with no way out, which is what this
    /// prevents.
    private let settleWithin: Duration
    /// How long a single hold may last. A stuck press must not hold the
    /// microphone open indefinitely.
    private let holdLimit: Duration
    /// Which session's events still count.
    ///
    /// A stream can deliver an event after the session it belongs to is over —
    /// cancelled by dragging off the button, or already failed — and applying
    /// it would put the screen back into a state the reader had left. It also
    /// stops the loop's tidy-up from overwriting a failure with "idle".
    private var liveSession: UUID?

    public init(
        transcriber: SpeechTranscriber,
        settleWithin: Duration = .seconds(5),
        holdLimit: Duration = .seconds(60)
    ) {
        self.transcriber = transcriber
        self.settleWithin = settleWithin
        self.holdLimit = holdLimit
    }

    public var isBusy: Bool {
        switch state {
        case .opening, .listening: return true
        case .idle, .failed: return false
        }
    }

    /// The transcript to show while the button is held.
    public var liveTranscript: String {
        if case let .listening(text) = state { return text }
        return ""
    }

    /// Voice mode was chosen. Ask for the microphone now: asked at the moment
    /// the button goes down, the prompt suspends the session while the
    /// give-up timer runs, so the first hold always failed even when the
    /// answer was yes.
    public func prepare() {
        Task { await transcriber.prepare() }
    }

    /// The button went down.
    public func begin() {
        guard !isBusy else { return }
        sentences = []
        partial = ""
        sawSessionOpen = false
        finishedTranscript = nil
        state = .opening
        let id = UUID()
        liveSession = id
        // A hold that never ends — a finger that never lifted, a gesture the
        // system dropped — must not keep the microphone open.
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.holdLimit ?? .seconds(60))
            guard let self, !Task.isCancelled, self.liveSession == id else { return }
            self.giveUp(id: id, reason: "Stopped listening after a minute.")
        }
        session = Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await self.transcriber.start()
                for await event in events {
                    guard self.liveSession == id else { return }
                    self.apply(event)
                }
                // The stream ended without a failure, so whatever was heard is
                // the result — unless this session is no longer the live one.
                guard self.liveSession == id else { return }
                self.settle()
            } catch {
                guard self.liveSession == id else { return }
                self.liveSession = nil
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    /// The button came up. The service needs telling before it will produce the
    /// last sentence, so the result arrives a moment later.
    public func end() {
        guard isBusy, let id = liveSession else { return }
        Task { await transcriber.finish() }
        // The final sentence arrives a moment later — or not at all.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.settleWithin ?? .seconds(5))
            guard let self, !Task.isCancelled, self.liveSession == id else { return }
            self.giveUp(id: id, reason: "Nothing was heard.")
        }
    }

    /// Give up — the reader dragged off the button, or left the screen.
    public func cancel() {
        liveSession = nil
        watchdog?.cancel()
        watchdog = nil
        session?.cancel()
        session = nil
        Task { await transcriber.cancel() }
        sentences = []
        partial = ""
        state = .idle
    }

    /// Take the finished text, which the composer does exactly once.
    public func takeTranscript() -> String? {
        defer { finishedTranscript = nil }
        return finishedTranscript
    }

    /// Clear a failure once it has been read.
    public func acknowledgeFailure() {
        if case .failed = state { state = .idle }
    }

    private func apply(_ event: SpeechProtocol.Event) {
        switch event {
        case .started:
            sawSessionOpen = true
            state = .listening(SpeechProtocol.transcript(sentences: sentences, partial: partial))
        case let .partial(text):
            partial = text
            state = .listening(SpeechProtocol.transcript(sentences: sentences, partial: partial))
        case let .sentence(text):
            // The service revises a sentence until it ends, then moves on.
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                sentences.append(text)
            }
            partial = ""
            state = .listening(SpeechProtocol.transcript(sentences: sentences, partial: partial))
        case .completed:
            settle()
        case let .failed(reason):
            state = .failed(reason)
            liveSession = nil
            session = nil
            watchdog?.cancel()
            watchdog = nil
        case .ignored:
            break
        }
    }

    /// The service stopped answering. Keep whatever was heard; when there is
    /// nothing, say which part came up empty rather than only that something
    /// did.
    private func giveUp(id: UUID, reason: String) {
        guard liveSession == id else { return }
        let text = SpeechProtocol.transcript(sentences: sentences, partial: partial)
        if !text.isEmpty {
            Task { await transcriber.cancel() }
            settle()
            return
        }
        let opened = sawSessionOpen
        liveSession = nil
        session = nil
        watchdog = nil
        state = .failed(reason)
        // Asking costs a hop, so it is only done once there is nothing to
        // show and the answer is the only thing left worth having.
        Task { [weak self] in
            guard let self else { return }
            let diagnosis = await self.transcriber.diagnosis()
            await self.transcriber.cancel()
            guard case .failed = self.state else { return }
            self.state = .failed(
                Self.explain(diagnosis, sessionOpened: opened, fallback: reason)
            )
        }
    }

    /// Turn what happened into the one sentence worth reading.
    ///
    /// Whether the session opened is this model's own knowledge — it saw the
    /// service acknowledge it — so only the audio is asked about.
    /// Pure, and deliberately not tied to the main actor: it is the wording
    /// rule, testable on its own.
    nonisolated public static func explain(
        _ diagnosis: DictationDiagnosis, sessionOpened: Bool, fallback: String
    ) -> String {
        if let error = diagnosis.lastAudioError {
            return "The connection to the speech service dropped: \(error)"
        }
        if !sessionOpened {
            guard let error = diagnosis.connectionError else {
                return "The speech service did not answer."
            }
            return "Could not reach the speech service: \(error)"
        }
        if diagnosis.droppedAudioFrames > 0 {
            return "The connection could not keep up: "
                + "\(diagnosis.droppedAudioFrames) frames of audio were dropped."
        }
        switch diagnosis.audioFramesSent {
        case 0:
            return "No sound reached the microphone."
        case let sent?:
            return "The speech service heard nothing in \(sent) frames of audio."
        case nil:
            return fallback
        }
    }

    private func settle() {
        let text = SpeechProtocol.transcript(sentences: sentences, partial: partial)
        liveSession = nil
        session = nil
        watchdog?.cancel()
        watchdog = nil
        state = .idle
        // Nothing heard is not a failure — a tap on the button rather than a
        // sentence — and an empty line in the composer would be noise.
        finishedTranscript = text.isEmpty ? nil : text
    }

    static func message(for error: Error) -> String {
        if case let AgentClientError.rejected(code) = error {
            switch code {
            case "speech_not_configured":
                return "Speech is not set up on the Mac."
            case "speech_no_account_key":
                return "The Mac has no speech account key."
            case "speech_rejected":
                return "The speech service refused the Mac's key."
            case "speech_unreachable":
                return "The Mac could not reach the speech service."
            default:
                break
            }
        }
        if case .microphoneDenied = error as? DictationFailure ?? .other {
            return "RemoteAI cannot use the microphone. Turn it on in Settings › RemoteAI."
        }
        return AppModel.userMessage(for: error)
    }
}

/// Failures the transcriber itself raises, as opposed to the Mac's.
public enum DictationFailure: Error, Equatable, Sendable {
    case microphoneDenied
    case audioUnavailable
    case connectionFailed
    case other
}

/// The press-and-hold control.
///
/// A drag gesture with no minimum distance rather than a long press: a long
/// press has a delay before it fires and no reliable release, and holding a
/// button that does nothing for half a second reads as broken.
@MainActor
struct HoldToTalkButton: View {
    @Bindable var dictation: VoiceDictation
    let isOnline: Bool
    @State private var isHeld = false

    var body: some View {
        VStack(spacing: 4) {
            if dictation.isBusy {
                // What the service has heard so far. Without it, holding the
                // button is an act of faith.
                Text(dictation.liveTranscript.isEmpty ? "Listening…" : dictation.liveTranscript)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
                    .accessibilityIdentifier("dictation-live-transcript")
            }
            Text(isHeld ? "Listening — release to stop" : "Hold to talk")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHeld ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("hold-to-talk")
                .accessibilityAddTraits(.isButton)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            // onChanged repeats for the whole hold.
                            guard !isHeld, isOnline else { return }
                            isHeld = true
                            dictation.begin()
                        }
                        .onEnded { _ in
                            guard isHeld else { return }
                            isHeld = false
                            dictation.end()
                        }
                )
        }
        .opacity(isOnline ? 1 : 0.5)
    }
}
