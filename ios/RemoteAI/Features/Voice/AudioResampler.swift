import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Turns whatever the microphone gives into what the speech service accepts.
///
/// Microphones do not offer 16 kHz mono 16-bit; a phone hands over 48 kHz
/// float. Every captured buffer is therefore converted, and this is the one
/// part of voice input that can be checked without a microphone, a network or
/// a speech account — which is why it lives on its own.
public struct AudioResampler {
    #if canImport(AVFoundation)
        private let converter: AVAudioConverter
        private let output: AVAudioFormat

        /// `nil` when the hardware's format cannot be converted at all.
        public init?(from hardware: AVAudioFormat) {
            guard hardware.sampleRate > 0,
                let output = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(SpeechProtocol.sampleRate),
                    channels: AVAudioChannelCount(SpeechProtocol.channels),
                    interleaved: true
                ),
                let converter = AVAudioConverter(from: hardware, to: output)
            else { return nil }
            self.converter = converter
            self.output = output
        }

        /// One captured buffer as the bytes the service expects, or `nil` when
        /// the converter had nothing to give yet — which happens for the first
        /// buffers of a rate conversion and is not a failure.
        public func resample(_ buffer: AVAudioPCMBuffer) -> Data? {
            let ratio = output.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
            guard capacity > 0,
                let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
            else { return nil }

            var consumed = false
            var failure: NSError?
            converter.convert(to: converted, error: &failure) { _, status in
                if consumed {
                    // The converter is asking for more than this buffer holds;
                    // it keeps what it has and returns it.
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard failure == nil, converted.frameLength > 0,
                let channel = converted.int16ChannelData
            else { return nil }
            return Data(
                bytes: channel[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size
            )
        }
    #endif
}
