import AVFoundation

/// The default microphone as a stream of 16 kHz mono Int16 chunks.
///
/// Taps the input node in its hardware format and converts afterwards — the input node does no
/// format conversion, so asking `installTap` for 16 kHz directly crashes (DESIGN.md §4.2).
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Int16]>.Continuation?

    public init() {}

    /// Asks for microphone access. For a command-line tool macOS asks on behalf of the terminal app.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// The input device's name, for display.
    public static var defaultInputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "default input"
    }

    public func start() throws -> AsyncStream<[Int16]> {
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { throw MemoirError.noInputDevice }
        let converter = try PCMConverter(inputFormat: hardwareFormat)
        let (stream, continuation) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { continuation.yield(samples) }
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
