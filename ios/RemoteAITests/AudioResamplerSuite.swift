import AVFoundation
import Foundation
import RemoteAIKit
import RemoteAITestKit

/// The one part of voice input that can be checked without a microphone: the
/// conversion from what a phone's hardware gives (48 kHz float) to what the
/// speech service accepts (16 kHz mono 16-bit).
///
/// Worth its own suite because a broken conversion is indistinguishable, from
/// the outside, from a service that heard nothing — which is how it went
/// unnoticed until a real device reported exactly that.
public enum AudioResamplerSuite {

    /// A second of a tone at the given rate, as a microphone would deliver it.
    private static func tone(
        sampleRate: Double, frames: AVAudioFrameCount, hertz: Double = 440
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2 * .pi * hertz * Double(index) / sampleRate)) * 0.5
        }
        return buffer
    }

    private static func energy(_ pcm: Data) -> Double {
        let samples = pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (total / Double(samples.count)).squareRoot()
    }

    public static let suite = TestSuite(
        name: "AudioResamplerSuite",
        cases: [
            TestCase("a phone's 48 kHz float becomes the service's 16 kHz 16-bit") {
                let resampler = try expectNotNil(
                    AudioResampler(
                        from: AVAudioFormat(
                            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                            interleaved: false
                        )!
                    )
                )

                let pcm = try expectNotNil(
                    resampler.resample(tone(sampleRate: 48_000, frames: 4_800)),
                    "a tenth of a second of speech must convert to something"
                )

                // Three-to-one, in 16-bit samples, less the converter's
                // startup latency: the first buffer comes back about 240
                // samples short and the steady state makes them up, which is
                // why the stream case below measures the total.
                let samples = pcm.count / 2
                try expectTrue(
                    (1_300...1_700).contains(samples),
                    "expected about 1600 samples from 4800, got \(samples)"
                )
                try expectTrue(
                    energy(pcm) > 1_000,
                    "the tone must survive the conversion, not arrive as silence "
                        + "(energy \(energy(pcm)))"
                )
            },

            TestCase("silence converts to silence rather than to nothing") {
                // Distinguishing "the microphone gave us silence" from "the
                // conversion produced nothing" is the whole point of the
                // frame count the failure message reports.
                let resampler = try expectNotNil(
                    AudioResampler(
                        from: AVAudioFormat(
                            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                            interleaved: false
                        )!
                    )
                )
                let quiet = tone(sampleRate: 48_000, frames: 4_800, hertz: 0)

                let pcm = try expectNotNil(resampler.resample(quiet))

                try expectTrue(pcm.count > 0, "silence still produces frames")
                try expectTrue(energy(pcm) < 10, "and they are quiet")
            },

            TestCase("a stream of buffers keeps converting, not just the first") {
                // The converter has internal latency: an implementation that
                // gave up when a buffer produced nothing would drop most of a
                // sentence.
                let resampler = try expectNotNil(
                    AudioResampler(
                        from: AVAudioFormat(
                            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                            interleaved: false
                        )!
                    )
                )

                var produced = 0
                var bytes = 0
                for _ in 0..<10 {
                    if let pcm = resampler.resample(tone(sampleRate: 48_000, frames: 4_800)) {
                        produced += 1
                        bytes += pcm.count
                    }
                }

                try expectTrue(
                    produced >= 9, "9 of 10 buffers should convert, got \(produced)"
                )
                try expectTrue(
                    bytes > 25_000,
                    "a second of speech is about 32000 bytes at 16 kHz, got \(bytes)"
                )
            },

            TestCase("hardware already at 16 kHz passes through") {
                let resampler = try expectNotNil(
                    AudioResampler(
                        from: AVAudioFormat(
                            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                            interleaved: false
                        )!
                    )
                )
                let pcm = try expectNotNil(
                    resampler.resample(tone(sampleRate: 16_000, frames: 1_600))
                )
                try expectEqual(pcm.count / 2, 1_600)
                try expectTrue(energy(pcm) > 1_000)
            },

            TestCase("a format with no sample rate is refused rather than half-used") {
                // What `inputNode.outputFormat` returns before the audio
                // session is active.
                let unusable = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1,
                    interleaved: false
                )
                try expectNil(unusable.flatMap(AudioResampler.init(from:)))
            },
        ]
    )
}
