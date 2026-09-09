import Foundation

/// The speech service's WebSocket protocol, as observed against the live
/// service rather than read off a page.
///
/// Kept apart from the socket and the microphone so the wire format can be
/// tested without either: every value below was captured from a real session.
public enum SpeechProtocol {
    /// The service groups everything under one namespace and correlates a
    /// session by `task_id` — which the documentation omits and the service
    /// requires.
    static let namespace = "SpeechTranscriber"

    /// Audio the service accepts: 16 kHz, single channel, signed 16-bit.
    public static let sampleRate = 16_000
    public static let channels = 1
    /// How much audio one frame carries. The service wants it at roughly the
    /// rate it was spoken; a tenth of a second keeps the transcript live
    /// without a frame per syllable.
    public static let frameMilliseconds = 100

    public static var framePayloadBytes: Int {
        sampleRate * frameMilliseconds / 1000 * 2
    }

    /// Everything the service says back, reduced to what the screen needs.
    public enum Event: Equatable, Sendable {
        /// The session is open and audio may flow.
        case started
        /// The transcript so far, revised as more is heard.
        case partial(String)
        /// A sentence the service considers finished.
        case sentence(String)
        /// The session is over.
        case completed
        /// The service refused, with its own status text.
        case failed(String)
        /// A message this build has no use for.
        case ignored(String)
    }

    /// An id the service will accept.
    ///
    /// Thirty-two lowercase hex characters. Foundation's `UUID` prints
    /// uppercase with hyphens, and the service rejects that outright:
    /// `Gateway:MESSAGE_INVALID:Invalid message id`. The case is the whole
    /// difference, which is why this is not left to the call site.
    public static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The opening command. `taskId` correlates every later frame.
    ///
    /// Returned as text, not bytes, because the distinction is the protocol:
    /// the service reads every binary frame as audio. Sent as binary, this
    /// command is swallowed as a moment of noise — the socket opens, nothing
    /// is acknowledged, and nothing ever answers.
    public static func startCommand(appkey: String, taskId: String, messageId: String) -> String {
        command(
            name: "StartTranscription", appkey: appkey, taskId: taskId, messageId: messageId,
            payload: [
                "format": "pcm",
                "sample_rate": sampleRate,
                // Without this there is nothing to show until the speaker
                // stops, and holding a button with no feedback feels broken.
                "enable_intermediate_result": true,
                "enable_punctuation_prediction": true,
                // "十行" rather than "10行" is what a person dictating means.
                "enable_inverse_text_normalization": true,
            ]
        )
    }

    /// Tells the service the audio has ended, which is what produces the final
    /// sentence. Text, for the same reason as `startCommand`.
    public static func stopCommand(appkey: String, taskId: String, messageId: String) -> String {
        command(
            name: "StopTranscription", appkey: appkey, taskId: taskId, messageId: messageId,
            payload: [:]
        )
    }

    private static func command(
        name: String, appkey: String, taskId: String, messageId: String,
        payload: [String: Any]
    ) -> String {
        let message: [String: Any] = [
            "header": [
                "namespace": namespace,
                "name": name,
                "appkey": appkey,
                "message_id": messageId,
                "task_id": taskId,
            ],
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: message, options: [.sortedKeys]
        ),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Read one message from the service.
    ///
    /// Anything unrecognised becomes `.ignored` rather than an error: the
    /// service sends events this app has no use for — sentence boundaries,
    /// word timings — and a stricter reader would turn a working session into
    /// a failure on the first of them.
    public static func event(from data: Data) -> Event {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let header = object["header"] as? [String: Any],
            let name = header["name"] as? String
        else { return .ignored("unreadable") }

        let payload = object["payload"] as? [String: Any]
        let result = payload?["result"] as? String

        switch name {
        case "TranscriptionStarted":
            return .started
        case "TranscriptionResultChanged":
            return .partial(result ?? "")
        case "SentenceEnd":
            return .sentence(result ?? "")
        case "TranscriptionCompleted":
            return .completed
        case "TaskFailed":
            // The status text is the service's own words and the only
            // explanation there is.
            return .failed(header["status_text"] as? String ?? "the speech service refused")
        default:
            return .ignored(name)
        }
    }

    /// The transcript to show, given the sentences already finished and the
    /// revision in flight.
    ///
    /// The service revises the sentence it is working on and only fixes it at
    /// `SentenceEnd`, so a screen that showed the partial alone would drop
    /// everything said before it.
    public static func transcript(sentences: [String], partial: String) -> String {
        (sentences + [partial])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined()
    }
}
