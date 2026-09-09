import Foundation
import RemoteAIKit
import RemoteAITestKit

/// The speech service's wire format, pinned against messages captured from the
/// live service. Every fixture below is a real reply, trimmed only in length.
public enum SpeechProtocolSuite {
    public static let suite = TestSuite(
        name: "SpeechProtocolSuite",
        cases: [
            TestCase("ids are lowercase hex, which is the only form accepted") {
                // Foundation's UUID prints uppercase with hyphens, and the
                // service answers `MESSAGE_INVALID` to that — the case is the
                // whole difference, and a real session died on it.
                let identifier = SpeechProtocol.identifier()
                try expectEqual(identifier.count, 32)
                try expectTrue(
                    identifier.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                    "expected 32 lowercase hex characters, got \(identifier)"
                )
                try expectFalse(identifier.contains("-"))
                try expectTrue(
                    SpeechProtocol.identifier() != identifier, "each session needs its own"
                )
            },

            TestCase("commands are text, because binary frames are audio") {
                // The service reads every binary frame as audio. Sent as
                // bytes, the opening command is swallowed as a moment of
                // noise: the socket opens, the session is never acknowledged,
                // and nothing ever answers — which is exactly what a real
                // device reported. The return type is what keeps it text.
                let command: String = SpeechProtocol.startCommand(
                    appkey: "an-appkey", taskId: "task-1", messageId: "message-1"
                )
                try expectTrue(command.hasPrefix("{"), "JSON text, not bytes: \(command)")
                let stop: String = SpeechProtocol.stopCommand(
                    appkey: "an-appkey", taskId: "task-1", messageId: "message-2"
                )
                try expectTrue(stop.contains("StopTranscription"))
            },

            TestCase("the opening command carries what the service requires") {
                let data = Data(
                    SpeechProtocol.startCommand(
                        appkey: "an-appkey", taskId: "task-1", messageId: "message-1"
                    ).utf8
                )
                let object = try expectNotNil(
                    try JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                let header = try expectNotNil(object["header"] as? [String: Any])
                try expectEqual(header["namespace"] as? String, "SpeechTranscriber")
                try expectEqual(header["name"] as? String, "StartTranscription")
                try expectEqual(header["appkey"] as? String, "an-appkey")
                // Undocumented and required: without task_id the service
                // rejects the session.
                try expectEqual(header["task_id"] as? String, "task-1")

                let payload = try expectNotNil(object["payload"] as? [String: Any])
                try expectEqual(payload["format"] as? String, "pcm")
                try expectEqual(payload["sample_rate"] as? Int, 16_000)
                try expectEqual(
                    payload["enable_intermediate_result"] as? Bool, true,
                    "a held button with no feedback reads as broken"
                )
            },

            TestCase("a session that has opened is recognised") {
                let started = Data(
                    #"""
                    {"header":{"namespace":"SpeechTranscriber","name":"TranscriptionStarted",
                     "status":20000000,"message_id":"74f6359","task_id":"f8bd291",
                     "status_text":"Gateway:SUCCESS:Success."}}
                    """#.utf8
                )
                try expectEqual(SpeechProtocol.event(from: started), .started)
            },

            TestCase("a revised transcript arrives as a partial") {
                let changed = Data(
                    #"""
                    {"header":{"namespace":"SpeechTranscriber",
                     "name":"TranscriptionResultChanged","status":20000000,
                     "message_id":"m","task_id":"t"},
                     "payload":{"index":1,"time":2640,"result":"今天天气不错，我们去",
                     "confidence":0.871,"words":[],"status":0}}
                    """#.utf8
                )
                try expectEqual(
                    SpeechProtocol.event(from: changed), .partial("今天天气不错，我们去")
                )
            },

            TestCase("the finished sentence is what the reader keeps") {
                let ended = Data(
                    #"""
                    {"header":{"namespace":"SpeechTranscriber","name":"SentenceEnd",
                     "status":20000000,"message_id":"m","task_id":"t"},
                     "payload":{"index":1,"time":3480,"result":"今天天气不错，我们去公园散步吧。",
                     "confidence":0.863,"begin_time":0}}
                    """#.utf8
                )
                try expectEqual(
                    SpeechProtocol.event(from: ended),
                    .sentence("今天天气不错，我们去公园散步吧。")
                )
            },

            TestCase("the end of the session is recognised") {
                let done = Data(
                    #"""
                    {"header":{"namespace":"SpeechTranscriber",
                     "name":"TranscriptionCompleted","status":20000000,
                     "message_id":"m","task_id":"t"},"payload":{}}
                    """#.utf8
                )
                try expectEqual(SpeechProtocol.event(from: done), .completed)
            },

            TestCase("a refusal keeps the service's own words") {
                let failed = Data(
                    #"""
                    {"header":{"namespace":"Default","name":"TaskFailed","status":40000004,
                     "message_id":"m","task_id":"t",
                     "status_text":"Gateway:CLIENT_ERROR:Client error!"}}
                    """#.utf8
                )
                try expectEqual(
                    SpeechProtocol.event(from: failed),
                    .failed("Gateway:CLIENT_ERROR:Client error!")
                )
            },

            TestCase("an event this build has no use for is not a failure") {
                // The service also sends sentence boundaries and word timings.
                // Treating the first of them as an error would break a working
                // session.
                let begin = Data(
                    #"""
                    {"header":{"namespace":"SpeechTranscriber","name":"SentenceBegin",
                     "status":20000000,"message_id":"m","task_id":"t"},
                     "payload":{"index":1,"time":0}}
                    """#.utf8
                )
                try expectEqual(SpeechProtocol.event(from: begin), .ignored("SentenceBegin"))
                try expectEqual(
                    SpeechProtocol.event(from: Data("not json".utf8)), .ignored("unreadable")
                )
            },

            TestCase("the shown transcript keeps the sentences already finished") {
                // The service revises only the sentence in flight. Showing the
                // partial alone would drop everything said before it.
                try expectEqual(
                    SpeechProtocol.transcript(
                        sentences: ["先跑一下测试。"], partial: "如果都过了"
                    ),
                    "先跑一下测试。如果都过了"
                )
                try expectEqual(
                    SpeechProtocol.transcript(sentences: [], partial: ""), ""
                )
                try expectEqual(
                    SpeechProtocol.transcript(sentences: ["一句话。"], partial: ""),
                    "一句话。"
                )
            },

            TestCase("one audio frame is a tenth of a second of 16-bit mono") {
                // Wrong framing is the difference between a live transcript and
                // an idle-timeout error.
                try expectEqual(SpeechProtocol.sampleRate, 16_000)
                try expectEqual(SpeechProtocol.channels, 1)
                try expectEqual(SpeechProtocol.framePayloadBytes, 3_200)
            },
        ]
    )
}
