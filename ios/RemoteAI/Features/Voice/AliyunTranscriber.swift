import Foundation

#if os(iOS)
    import AVFoundation
#endif

/// Streams the microphone to the speech service and yields what it hears.
///
/// The audio goes from this phone straight to the service. It does not pass
/// through the Mac: routing every syllable through the tunnel would add a
/// round trip to a transcript that is supposed to keep up with speech. What
/// the Mac provides is the token, because the account key that mints one must
/// not live on a phone.
public actor AliyunTranscriber: SpeechTranscriber {
    /// How long the service gets to acknowledge the session before the app
    /// says why it could not be reached.
    ///
    /// A host that is blocked rather than absent produces no error: the
    /// packets are dropped and the socket waits indefinitely. Without a
    /// deadline the reader waits with it, and all the screen can say is that
    /// nothing answered.
    /// How long the service gets to acknowledge a session on a socket that is
    /// already open. It answers in a fraction of a second, so silence this
    /// long is a fault in what was sent, not slowness.
    private static let acknowledgeWithin = Duration.seconds(4)

    /// How long the socket itself gets to open. Longer, because this covers
    /// DNS, TCP and TLS on whatever network the phone is on — and a host that
    /// is blocked rather than absent reports nothing at all until its own
    /// timeout, which is far longer than anyone will hold a button.
    private static let connectWithin = Duration.seconds(10)

    /// How many converted buffers may wait for the socket — ten seconds of
    /// speech. Beyond that the connection is not keeping up and dropping is
    /// the only option left.
    private static let queuedFrameLimit = 100

    private let client: AgentClient
    private var credentials: SpeechCredentials?
    private let monitor = SocketMonitor()
    private var openDeadline: Task<Void, Never>?
    private var sessionOpened = false

    private var socket: URLSessionWebSocketTask?
    private var continuation: AsyncStream<SpeechProtocol.Event>.Continuation?
    private var taskId = ""
    private var pump: Task<Void, Never>?
    /// Kept so that a session which produced no words can say which part came
    /// up empty: a service never reached, a microphone that yielded nothing,
    /// or audio the service made nothing of.
    private var report = DictationDiagnosis()
    private var isCapturing = false
    /// Captured audio on its way to the socket.
    ///
    /// One ordered queue rather than a task per buffer: independently created
    /// tasks entering an actor have no guaranteed order, so frames could
    /// reach the service reversed and it would transcribe scrambled audio —
    /// with nothing anywhere reporting an error.
    private var audio: AsyncStream<Data>.Continuation?
    private var audioPump: Task<Void, Never>?

    #if os(iOS)
        private let engine = AVAudioEngine()
    #endif

    public init(client: AgentClient) {
        self.client = client
    }

    /// Ask for the microphone, and warm the token, before the button is held.
    public func prepare() async {
        try? await requireMicrophone()
        if credentials?.isUsable() != true {
            credentials = try? await client.speechCredentials()
        }
    }

    public func diagnosis() async -> DictationDiagnosis {
        var current = report
        current.connectionError = current.connectionError ?? monitor.failure
        return current
    }

    public func start() async throws -> AsyncStream<SpeechProtocol.Event> {
        // Never leave a previous session's socket, reader or microphone tap
        // running: a second tap on the same bus throws, and a second reader
        // would deliver into a finished stream.
        await cancel()
        report = DictationDiagnosis(audioFramesSent: 0)
        // A token lasts days, so it is fetched once and reused; the Mac is only
        // asked again when this one is nearly out.
        if credentials?.isUsable() != true {
            credentials = try await client.speechCredentials()
        }
        guard let credentials else { throw DictationFailure.connectionFailed }
        try await requireMicrophone()

        let (stream, continuation) = AsyncStream<SpeechProtocol.Event>.makeStream()
        self.continuation = continuation
        taskId = SpeechProtocol.identifier()

        guard var components = URLComponents(string: credentials.endpoint) else {
            throw DictationFailure.connectionFailed
        }
        components.scheme = components.scheme == "ws" ? "ws" : "wss"
        guard let url = components.url else { throw DictationFailure.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue(credentials.token, forHTTPHeaderField: "X-NLS-Token")
        // A session of its own, with a delegate: the reason a socket never
        // opened is only reported there, and `URLSession.shared` cannot carry
        // one.
        monitor.reset()
        let session = URLSession(
            configuration: .ephemeral, delegate: monitor, delegateQueue: nil
        )
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        sessionOpened = false
        socket.resume()

        try await send(
            command: SpeechProtocol.startCommand(
                appkey: credentials.appkey, taskId: taskId, messageId: Self.messageId()
            )
        )
        pump = Task { await self.readEvents() }

        // The tap yields into this stream, in order, and one consumer sends
        // them one at a time. Bounded, because a socket that stalls must not
        // grow the queue without limit; a drop is recorded so a session that
        // produced nothing can say audio was lost rather than blame the
        // microphone.
        let (frames, audio) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.queuedFrameLimit)
        )
        self.audio = audio
        audioPump = Task { [weak self] in
            for await pcm in frames {
                guard let self else { return }
                await self.sendAudio(pcm)
            }
        }
        // Say why rather than waiting for the hold to end: the reader is
        // still holding the button, and a blocked host never errors on its
        // own.
        openDeadline = Task { [weak self] in
            try? await Task.sleep(for: Self.acknowledgeWithin)
            guard let self, !Task.isCancelled else { return }
            // A socket that is open and silent is a different fault from one
            // that never opened, and only the first is already conclusive.
            if await self.socketDidOpen {
                await self.reportUnopened()
                return
            }
            try? await Task.sleep(for: Self.connectWithin - Self.acknowledgeWithin)
            guard !Task.isCancelled else { return }
            await self.reportUnopened()
        }

        try startCapturing(into: audio)
        return stream
    }

    public func finish() async {
        stopCapturing()
        // Let the frames already queued go out before the service is told the
        // audio has ended; dropping them here would clip the last word.
        audio?.finish()
        audio = nil
        await audioPump?.value
        audioPump = nil
        guard let credentials else { return }
        // The service only produces the final sentence once it is told the
        // audio has ended.
        try? await send(
            command: SpeechProtocol.stopCommand(
                appkey: credentials.appkey, taskId: taskId, messageId: Self.messageId()
            )
        )
    }

    public func cancel() async {
        stopCapturing()
        audio?.finish()
        audio = nil
        audioPump?.cancel()
        audioPump = nil
        openDeadline?.cancel()
        openDeadline = nil
        pump?.cancel()
        pump = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Socket

    /// Commands travel as text frames. The service reads every binary frame
    /// as audio, so a command sent as bytes is swallowed as noise: the socket
    /// opens, the session is never acknowledged, and nothing ever answers.
    private func send(command: String) async throws {
        guard let socket else { throw DictationFailure.connectionFailed }
        do {
            try await socket.send(.string(command))
        } catch {
            throw DictationFailure.connectionFailed
        }
    }

    private func readEvents() async {
        guard let socket else { return }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                // A closed socket ends the session; whatever was heard stands.
                continuation?.finish()
                return
            }
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value): data = Data(value.utf8)
            @unknown default: continue
            }
            let event = SpeechProtocol.event(from: data)
            if case .started = event {
                sessionOpened = true
                openDeadline?.cancel()
                openDeadline = nil
            }
            continuation?.yield(event)
            if case .completed = event { break }
            if case .failed = event { break }
        }
        continuation?.finish()
        continuation = nil
    }

    var socketDidOpen: Bool { monitor.opened }

    /// The deadline passed with no acknowledgement: end the session with the
    /// most specific reason available, which is more use than silence.
    private func reportUnopened() {
        guard !sessionOpened else { return }
        let reason =
            monitor.failure
            ?? (monitor.opened
                ? "connected, but the service did not start the session — "
                    + "the app may be out of date"
                : "could not connect within \(Self.connectWithin)")
        report.connectionError = reason
        continuation?.yield(.failed("Could not reach the speech service: \(reason)"))
        continuation?.finish()
        continuation = nil
    }

    private static func messageId() -> String { SpeechProtocol.identifier() }

    // MARK: - Microphone

    private func requireMicrophone() async throws {
        #if os(iOS)
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return
            case .denied:
                throw DictationFailure.microphoneDenied
            case .undetermined:
                let granted = await AVAudioApplication.requestRecordPermission()
                if !granted { throw DictationFailure.microphoneDenied }
            @unknown default:
                throw DictationFailure.microphoneDenied
            }
        #else
            throw DictationFailure.audioUnavailable
        #endif
    }

    /// The queue is passed in rather than read back off the actor: the tap
    /// runs on the audio thread, and waiting for an actor there would be the
    /// wrong thing to do. A continuation is safe to use from any thread and
    /// keeps the order the buffers arrived in.
    private func startCapturing(into queue: AsyncStream<Data>.Continuation) throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .measurement, options: [])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                throw DictationFailure.audioUnavailable
            }

            let input = engine.inputNode
            let hardware = input.outputFormat(forBus: 0)
            // The service wants 16 kHz mono 16-bit; microphones do not offer
            // that, so every buffer is converted.
            guard let resampler = AudioResampler(from: hardware) else {
                throw DictationFailure.audioUnavailable
            }

            // Defensive: a tap left behind by a session that failed between
            // installing and starting would make this throw.
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4_096, format: hardware) {
                [weak self] buffer, _ in
                guard let self, let pcm = resampler.resample(buffer) else { return }
                if case .dropped = queue.yield(pcm) {
                    Task { await self.noteDroppedAudio() }
                }
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw DictationFailure.audioUnavailable
            }
            isCapturing = true
        #else
            throw DictationFailure.audioUnavailable
        #endif
    }

    private func stopCapturing() {
        #if os(iOS)
            guard isCapturing else { return }
            isCapturing = false
            engine.stop()
            // Removed unconditionally: keying this off `engine.isRunning` left
            // the tap installed whenever the engine had already stopped on its
            // own, and the next session's install then threw.
            engine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private func noteDroppedAudio() {
        report.droppedAudioFrames += 1
    }

    private func sendAudio(_ pcm: Data) async {
        guard let socket else { return }
        do {
            try await socket.send(.data(pcm))
            report.audioFramesSent = (report.audioFramesSent ?? 0) + 1
        } catch {
            // Swallowing this was how a dropped connection came out as
            // "nothing was heard".
            report.lastAudioError = (error as NSError).localizedDescription
        }
    }

}


/// Records why a WebSocket never opened, or why it closed.
///
/// `URLSessionWebSocketTask` reports none of this through `receive()`: a
/// dropped connection to a blocked host simply never returns. The delegate is
/// the only place the reason appears.
private final class SocketMonitor: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: String?
    private var didOpen = false

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Whether the WebSocket handshake completed. The difference between a
    /// network that cannot reach the service and a service that would not
    /// start the session — which read identically until this was recorded.
    var opened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOpen
    }

    func reset() {
        lock.lock()
        recorded = nil
        didOpen = false
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        didOpen = true
        lock.unlock()
    }

    private func record(_ reason: String) {
        lock.lock()
        if recorded == nil { recorded = reason }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        record(
            text.isEmpty
                ? "the service closed the connection (code \(closeCode.rawValue))"
                : "the service closed the connection: \(text)"
        )
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        record((error as NSError).localizedDescription)
    }
}
