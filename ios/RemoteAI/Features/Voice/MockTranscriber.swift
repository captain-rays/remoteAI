import Foundation

/// A transcriber that recites a fixed sentence, the way the real one would.
///
/// Used by `-UseMockAgent` launches so the voice path is exercisable without a
/// microphone, a network, or a speech account — which is what lets a UI test
/// hold the button and check what lands in the composer.
public actor MockTranscriber: SpeechTranscriber {
    private let sentence: String
    private let step: Duration
    private var continuation: AsyncStream<SpeechProtocol.Event>.Continuation?
    private var narration: Task<Void, Never>?

    public init(sentence: String = "跑一下测试，如果都过了就提交。", step: Duration = .milliseconds(120)) {
        self.sentence = sentence
        self.step = step
    }

    public func start() async throws -> AsyncStream<SpeechProtocol.Event> {
        let (stream, continuation) = AsyncStream<SpeechProtocol.Event>.makeStream()
        self.continuation = continuation
        narration = Task { await self.narrate() }
        return stream
    }

    /// Reveals the sentence a few characters at a time, so a live transcript
    /// has something to show.
    private func narrate() async {
        continuation?.yield(.started)
        let characters = Array(sentence)
        var shown = ""
        for character in characters {
            if Task.isCancelled { return }
            shown.append(character)
            continuation?.yield(.partial(shown))
            try? await Task.sleep(for: step)
        }
    }

    public func finish() async {
        narration?.cancel()
        continuation?.yield(.sentence(sentence))
        continuation?.yield(.completed)
        continuation?.finish()
        continuation = nil
    }

    public func cancel() async {
        narration?.cancel()
        continuation?.finish()
        continuation = nil
    }
}
