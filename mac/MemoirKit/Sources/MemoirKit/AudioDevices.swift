import CoreAudio
import Foundation

/// An audio input device: Core Audio's id (valid until it's unplugged), its UID (stable across
/// reconnects and restarts) and its name (what Settings stores in the config — readable, and the same
/// for a device that's unplugged).
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

/// The Mac's audio inputs, for choosing the microphone (DESIGN.md §4.2).
public enum AudioDevices {
    /// Every device with input channels, except the aggregates Core Audio builds for apps on the fly.
    public static func inputs() -> [AudioInputDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device).filter { !$0.uid.hasPrefix("CADefaultDeviceAggregate") }
    }

    /// The input macOS uses by default (System Settings › Sound › Input).
    public static func defaultInput() -> AudioInputDevice? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return device(id)
    }

    /// The input `key` names — a UID, else a name — among `devices`; nil if it isn't connected.
    public static func find(_ key: String, in devices: [AudioInputDevice] = inputs()) -> AudioInputDevice? {
        devices.first { $0.uid == key } ?? devices.first { $0.name == key }
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Notices a microphone that delivers nothing (DESIGN.md §4.2): a MacBook's built-in mic with the lid
/// closed, a muted or unplugged interface. A working mic is never digitally silent — even in a quiet
/// room its noise floor is around −60 dBFS (the C920 measured −37 dBFS) — while a dead one sends exact
/// zeros. So it watches the raw mic (before the echo gate, which silences on purpose) and reports once
/// nothing has risen above `quietPeak` for `limit` seconds of audio, and again when sound comes back.
public final class SilenceWatch: @unchecked Sendable {
    public enum Change: Sendable, Equatable {
        case silent  // nothing for `limit` seconds
        case heard  // sound again after `silent`
    }

    public struct Stats: Sendable {
        /// Audio in stretches of `limit` seconds or longer with nothing in them.
        public var silentSeconds: Double
        public var micSeconds: Double
    }

    /// The loudest sample that still counts as silence (≈ −80 dBFS; a working mic's floor is 20+ dB above).
    public static let quietPeak: Int16 = 3
    public let limit: Double

    private let lock = NSLock()
    private var run = 0  // samples since the last sound
    private var total = 0
    private var silentSamples = 0  // finished stretches of `limit` or longer
    private var reported = false
    private var pending: Change?

    public init(limit: Double = 30) {
        self.limit = limit
    }

    /// Raw mic samples (16 kHz). Returns a change when there is one; it's also kept for `take()`.
    @discardableResult
    public func observe(_ samples: [Int16]) -> Change? {
        let isLoud = { (s: Int16) in s > Self.quietPeak || s < -Self.quietPeak }
        let first = samples.firstIndex(where: isLoud)
        let last = samples.lastIndex(where: isLoud)
        return lock.withLock {
            total += samples.count
            var change: Change?
            if let first, let last {
                if Double(run + first) >= limitSamples { silentSamples += run + first }
                if reported { change = .heard }
                reported = false
                run = samples.count - 1 - last
            } else {
                run += samples.count
                if !reported, Double(run) >= limitSamples {
                    reported = true
                    change = .silent
                }
            }
            if let change { pending = change }
            return change
        }
    }

    /// The last change not taken yet.
    public func take() -> Change? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    public var stats: Stats {
        lock.withLock {
            let ongoing = Double(run) >= limitSamples ? run : 0
            let rate = Double(Wire.sampleRate)
            return Stats(silentSeconds: Double(silentSamples + ongoing) / rate, micSeconds: Double(total) / rate)
        }
    }

    private var limitSamples: Double { limit * Double(Wire.sampleRate) }
}
