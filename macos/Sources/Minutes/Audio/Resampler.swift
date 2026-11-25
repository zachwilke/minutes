import AVFoundation

/// Converts arbitrary device audio into the one format everything downstream
/// wants: 16 kHz mono float. Whisper requires it, Apple's transcriber accepts
/// it, and it keeps the mixer arithmetic trivial.
final class Resampler {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(WAVWriter.sampleRate),
                                            channels: 1,
                                            interleaved: false)!

    private let converter: AVAudioConverter
    let inputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            Log.error("No converter from \(inputFormat) to 16 kHz mono")
            return nil
        }
        // Downmix rather than dropping extra channels, so a stereo interface
        // doesn't silently lose half the room.
        converter.downmix = true
        self.converter = converter
    }

    /// False once a device change has handed us buffers in a different format;
    /// the converter is built for one input format and would mangle another.
    func accepts(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == inputFormat.sampleRate
            && format.channelCount == inputFormat.channelCount
            && format.commonFormat == inputFormat.commonFormat
    }

    /// Returns the resampled samples. The converter keeps state between calls,
    /// so successive buffers stitch together without clicks at the seams.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return []
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            Log.warn("Resample failed: \(error.localizedDescription)")
            return []
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
