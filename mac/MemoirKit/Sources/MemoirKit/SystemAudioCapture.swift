import AVFoundation
import CoreAudio

/// Everything the Mac plays (except memoir itself) as a stream of 16 kHz mono Int16 chunks.
///
/// A Core Audio process tap (macOS 14.2+) inside a private aggregate device on the default output
/// (DESIGN.md §4.1). The audio is taken before the speakers, so speakers or headphones don't matter.
/// There is no API to check the permission: when "System Audio Recording" is denied, every call
/// succeeds and the buffers are silent.
public final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Int16]>.Continuation?
    private let queue = DispatchQueue(label: "memoir.system-audio", qos: .userInteractive)
    /// Sees each chunk, with the host time (s) of its first sample — the echo gate's reference.
    private let observe: (@Sendable ([Int16], Double) -> Void)?

    /// Name of the output device the tap is attached to, and the tap's native format — for display.
    public private(set) var outputDeviceName = ""
    public private(set) var tapFormat = ""

    public init(observe: (@Sendable ([Int16], Double) -> Void)? = nil) {
        self.observe = observe
    }

    public func start() throws -> AsyncStream<[Int16]> {
        let ownProcess = CoreAudioProperty.processObject(pid: getpid())
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        tap.name = "memoir"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted  // keep playing to the speakers
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create the process tap")

        var description = try CoreAudioProperty.get(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw MemoirError.converter("tap format \(description)")
        }
        tapFormat = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"

        let outputID = try CoreAudioProperty.get(AudioObjectID(kAudioObjectSystemObject),
                                                 kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID())
        let outputUID = try CoreAudioProperty.string(outputID, kAudioDevicePropertyDeviceUID)
        outputDeviceName = (try? CoreAudioProperty.string(outputID, kAudioObjectPropertyName)) ?? outputUID

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "memoir-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,  // required for TapAutoStart
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create the aggregate device")

        let converter = try PCMConverter(inputFormat: format)
        let (stream, continuation) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let observe = observe
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            let samples = converter.convert(buffer)
            guard !samples.isEmpty else { return }
            if let observe {
                let stamp = inputTime.pointee
                observe(samples, HostTime.seconds(stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil))
            }
            continuation.yield(samples)
        }, "create the IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start the aggregate device")
        return stream
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr {
            stop()
            throw MemoirError.coreAudio(what: what, status: status)
        }
    }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        _ initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw MemoirError.coreAudio(what: "read property \(selector)", status: status) }
        return value
    }

    /// CFString properties come back retained (+1).
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw MemoirError.coreAudio(what: "read property \(selector)", status: status) }
        return value.takeRetainedValue() as String
    }

    /// The Core Audio process object for a PID, or nil if that process isn't known to Core Audio.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
