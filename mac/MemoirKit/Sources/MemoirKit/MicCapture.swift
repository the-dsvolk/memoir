import AudioToolbox
import AVFoundation

/// A microphone as a stream of 16 kHz mono Int16 chunks — the one chosen in Settings (`mic` in the
/// config), else the system default input (DESIGN.md §4.2).
///
/// Taps the input node in its hardware format and converts afterwards — the input node does no
/// format conversion, so asking `installTap` for 16 kHz directly crashes (DESIGN.md §4.2).
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Int16]>.Continuation?
    /// Runs on each chunk, with the host time (s) of its first sample, before it's yielded — the echo gate.
    private let process: (@Sendable ([Int16], Double) -> [Int16])?
    /// The mic chosen in Settings: a device UID or name; nil or "" for the system default.
    private let device: String?
    /// Sees the raw audio, before `process` — for noticing a mic that sends nothing.
    private let silence: SilenceWatch?

    /// The device in use, once started.
    public private(set) var deviceName = "default input"
    /// Set when the chosen mic isn't connected and the system default is used instead.
    public private(set) var missingDevice: String?

    public init(device: String? = nil, silence: SilenceWatch? = nil,
                process: (@Sendable ([Int16], Double) -> [Int16])? = nil) {
        self.device = device
        self.silence = silence
        self.process = process
    }

    /// Asks for microphone access. For a command-line tool macOS asks on behalf of the terminal app.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func start() throws -> AsyncStream<[Int16]> {
        let input = engine.inputNode
        var chosen: AudioInputDevice?
        if let device, !device.isEmpty {
            chosen = AudioDevices.find(device)
            if chosen == nil { missingDevice = device }
        }
        if let chosen {
            guard let unit = input.audioUnit else { throw MemoirError.noInputDevice }
            var id = chosen.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw MemoirError.coreAudio(what: "select the microphone \(chosen.name)", status: status)
            }
            deviceName = chosen.name
        } else {
            deviceName = AudioDevices.defaultInput()?.name ?? "default input"
        }
        // The device's own format: after switching devices the node's output format still describes the
        // default input, and a tap in that format gets no audio (seen with a C920: 2 ch at 16 kHz).
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: hardware.channelCount)
        else { throw MemoirError.noInputDevice }
        let converter = try PCMConverter(inputFormat: format)
        let (stream, continuation) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let process = process
        let silence = silence
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            var samples = converter.convert(buffer)
            guard !samples.isEmpty else { return }
            silence?.observe(samples)
            if let process { samples = process(samples, HostTime.seconds(when.isHostTimeValid ? when.hostTime : nil)) }
            continuation.yield(samples)
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

/// Capture timestamps on one clock: the host clock (mach_absolute_time), in seconds — what the mic's
/// `AVAudioTime` and the system tap's `AudioTimeStamp` both carry.
enum HostTime {
    static func seconds(_ hostTime: UInt64?) -> Double {
        AVAudioTime.seconds(forHostTime: hostTime ?? mach_absolute_time())
    }
}
