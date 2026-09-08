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
    private let client: AgentClient
    private var credentials: SpeechCredentials?

    private var socket: URLSessionWebSocketTask?
    private var continuation: AsyncStream<SpeechProtocol.Event>.Continuation?
    private var taskId = ""
    private var pump: Task<Void, Never>?
    /// Kept so that a session which produced no words can say which part came
    /// up empty: a service never reached, a microphone that yielded nothing,
    /// or audio the service made nothing of.
    private var report = DictationDiagnosis()
    private var isCapturing = false

    #if os(iOS)
        private let engine = AVAudioEngine()
    #endif

    public init(client: AgentClient) {
        self.client = client
    }

    public func diagnosis() async -> DictationDiagnosis { report }

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
        taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        guard var components = URLComponents(string: credentials.endpoint) else {
            throw DictationFailure.connectionFailed
        }
        components.scheme = components.scheme == "ws" ? "ws" : "wss"
        guard let url = components.url else { throw DictationFailure.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue(credentials.token, forHTTPHeaderField: "X-NLS-Token")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        try await send(
            SpeechProtocol.startCommand(
                appkey: credentials.appkey, taskId: taskId, messageId: Self.messageId()
            )
        )
        pump = Task { await self.readEvents() }
        try startCapturing()
        return stream
    }

    public func finish() async {
        stopCapturing()
        guard let credentials else { return }
        // The service only produces the final sentence once it is told the
        // audio has ended.
        try? await send(
            SpeechProtocol.stopCommand(
                appkey: credentials.appkey, taskId: taskId, messageId: Self.messageId()
            )
        )
    }

    public func cancel() async {
        stopCapturing()
        pump?.cancel()
        pump = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Socket

    private func send(_ data: Data) async throws {
        guard let socket else { throw DictationFailure.connectionFailed }
        do {
            try await socket.send(.data(data))
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
            continuation?.yield(event)
            if case .completed = event { break }
            if case .failed = event { break }
        }
        continuation?.finish()
        continuation = nil
    }

    private static func messageId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

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

    private func startCapturing() throws {
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
                Task { await self.sendAudio(pcm) }
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
