import AVFoundation
import Foundation

/// PCM16 mono little-endian, the wire format of the realtime audio events.
enum RealtimePCM16 {
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let v = max(-1, min(1, s))
                out[i] = Int16(v * 32767).littleEndian
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }

    static func decodeBase64(_ text: String) -> [Float]? {
        Data(base64Encoded: text).map(decode)
    }
}

/// Converts the app's audio to the input format of the session: mono Float32
/// at the target rate. Keeps the resampler state between chunks, so a stream
/// of chunks resamples like one buffer. Not thread-safe.
final class RealtimeAudioResampler {
    let targetRate: Double
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    init(targetRate: Double) throws {
        self.targetRate = targetRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                         channels: 1, interleaved: false) else {
            throw LlamaError.invalidArgument("unsupported realtime input rate \(targetRate)")
        }
        outputFormat = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        if buffer.format.sampleRate == targetRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        if inputFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw LlamaError.invalidArgument("cannot convert \(buffer.format) to the realtime input format")
            }
            c.downmix = true
            converter = c
            inputFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw LlamaError.internalError("cannot allocate the resampling buffer")
        }

        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                // more input comes with the next chunk: keep the resampler state
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw LlamaError.invalidArgument(error?.localizedDescription ?? "audio conversion failed")
        }
        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// The samples the resampler still holds, at the end of a turn.
    func flush() throws -> [Float] {
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return [] }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        converter.reset()
        if status == .error {
            throw LlamaError.invalidArgument(error?.localizedDescription ?? "audio conversion failed")
        }
        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    func convert(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        if samples.isEmpty {
            return []
        }
        if sampleRate == targetRate {
            return samples
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw LlamaError.invalidArgument("unsupported sample rate \(sampleRate)")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return try convert(buffer)
    }
}
