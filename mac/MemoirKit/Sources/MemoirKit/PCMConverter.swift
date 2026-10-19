import AVFoundation

public enum MemoirError: Error, CustomStringConvertible {
    case converter(String)
    case noInputDevice
    case microphoneDenied
    case server(code: String, message: String)
    case unexpectedMessage
    case coreAudio(what: String, status: OSStatus)

    public var description: String {
        switch self {
        case .converter(let format): "can't convert from \(format) to 16 kHz mono"
        case .noInputDevice: "no audio input device"
        case .microphoneDenied: "microphone access denied — allow it for your terminal app in System Settings › Privacy & Security › Microphone"
        case .server(let code, let message): "server error \(code): \(message)"
        case .unexpectedMessage: "unexpected message from the server"
        case .coreAudio(let what, let status): "Core Audio couldn't \(what) (OSStatus \(status))"
        }
    }
}

/// Converts any PCM buffer to 16 kHz mono Int16. Keeps resampler state between calls, so feed one
/// continuous stream per converter. Not thread-safe: use it from one thread (the audio tap).
public final class PCMConverter: @unchecked Sendable {
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(Wire.sampleRate), channels: 1, interleaved: true)!

    private let converter: AVAudioConverter
    private let ratio: Double

    public init(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw MemoirError.converter(inputFormat.description)
        }
        converter.downmix = true
        self.converter = converter
        self.ratio = Self.outputFormat.sampleRate / inputFormat.sampleRate
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow  // not .endOfStream: keep the resampler primed
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

public enum AudioFile {
    /// Reads any audio file AVFoundation can open and returns it as 16 kHz mono Int16.
    public static func load(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return try PCMConverter(inputFormat: file.processingFormat).convert(buffer)
    }
}
