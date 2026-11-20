import Foundation
import Testing
@testable import MemoirKit

// MARK: - SilenceWatch (a dead mic: the lid closed, a muted interface)

private let second = Wire.sampleRate

/// `seconds` of audio in 0.25 s chunks: exact zeros, or a quiet room's noise floor (≈ −60 dBFS, ±32).
private func feed(_ watch: SilenceWatch, seconds: Double, noise: Bool) -> [SilenceWatch.Change] {
    var changes: [SilenceWatch.Change] = []
    let chunk = second / 4
    for i in 0 ..< Int(seconds * 4) {
        let samples = noise ? (0 ..< chunk).map { Int16(($0 * 7 + i) % 65) - 32 } : [Int16](repeating: 0, count: chunk)
        if let change = watch.observe(samples) { changes.append(change) }
    }
    return changes
}

@Test func silenceWatchWarnsAfterThirtySecondsOfZeros() {
    let watch = SilenceWatch(limit: 30)
    #expect(feed(watch, seconds: 29.75, noise: false).isEmpty)
    #expect(feed(watch, seconds: 0.25, noise: false) == [.silent])
    #expect(watch.take() == .silent)
    #expect(watch.take() == nil)  // taken once
    #expect(feed(watch, seconds: 60, noise: false).isEmpty)  // reported once, not every chunk
    #expect(feed(watch, seconds: 1, noise: true) == [.heard])
    #expect(watch.stats.silentSeconds == 90)
    #expect(watch.stats.micSeconds == 91)
}

@Test func silenceWatchIgnoresAQuietRoomAndPauses() {
    // A working mic while I'm quiet for minutes: its noise floor is far above `quietPeak`.
    let watch = SilenceWatch(limit: 30)
    #expect(feed(watch, seconds: 120, noise: true).isEmpty)
    #expect(watch.stats.silentSeconds == 0)
    // Dropouts shorter than the limit (a device switch, a glitch) aren't a dead mic either.
    #expect(feed(watch, seconds: 10, noise: false).isEmpty)
    #expect(feed(watch, seconds: 5, noise: true).isEmpty)
    #expect(watch.stats.silentSeconds == 0)
}

@Test func silenceWatchCountsAnOngoingStretch() {
    let watch = SilenceWatch(limit: 30)
    _ = feed(watch, seconds: 5, noise: true)
    _ = feed(watch, seconds: 40, noise: false)  // the call ends while it's still silent
    #expect(watch.stats.silentSeconds == 40)
    #expect(watch.take() == .silent)
}

@Test func silenceWatchTreatsDitherAsSilence() {
    // ±1–3 LSB (dither, a converter's rounding) is still nothing.
    let watch = SilenceWatch(limit: 1)
    #expect(watch.observe([Int16](repeating: 3, count: second)) == .silent)
    #expect(watch.observe([0, -3, 2, 0]) == nil)
    #expect(watch.observe([0, 0, 4]) == .heard)
}

// MARK: - Choosing the mic

@Test func findMicByUIDThenName() {
    let builtIn = AudioInputDevice(id: 93, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")
    let webcam = AudioInputDevice(id: 113, uid: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:882B2D4F:3",
                                  name: "HD Pro Webcam C920")
    let devices = [builtIn, webcam]
    #expect(AudioDevices.find("HD Pro Webcam C920", in: devices) == webcam)
    #expect(AudioDevices.find("BuiltInMicrophoneDevice", in: devices) == builtIn)
    #expect(AudioDevices.find("Yeti", in: devices) == nil)
}

@Test func audioInputsAreReal() {
    // On any Mac with an input: names and UIDs filled in, Core Audio's on-the-fly aggregates left out.
    for device in AudioDevices.inputs() {
        #expect(!device.uid.isEmpty && !device.name.isEmpty)
        #expect(!device.uid.hasPrefix("CADefaultDeviceAggregate"))
    }
}

// MARK: - Config

@Test func configSaveKeepsCommentsAndAddsMic() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-mic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("config.toml").path
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try """
        # memoir settings
        # server -> local tunnel (launchd com.memoir.spark-tunnel), 2026-11-15
        save_dir   = "~/memoir"
        server     = "ws://127.0.0.1:8770/v1/stream"
        echo_gate  = true
        # mic = "old"
        """.write(toFile: path, atomically: true, encoding: .utf8)

    var config = MemoirConfig.load(path: path)
    #expect(config.mic == "" && config.server == "ws://127.0.0.1:8770/v1/stream")
    config.mic = "HD Pro Webcam C920"
    config.echoGate = false
    try config.save(path: path)

    let text = try String(contentsOfFile: path, encoding: .utf8)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines[1] == "# server -> local tunnel (launchd com.memoir.spark-tunnel), 2026-11-15")  // kept
    #expect(lines[3] == "server     = \"ws://127.0.0.1:8770/v1/stream\"")  // in place
    #expect(lines[4] == "echo_gate  = false")  // changed in place
    #expect(lines[5] == "# mic = \"old\"")  // a commented-out setting stays a comment
    #expect(lines.contains("mic        = \"HD Pro Webcam C920\""))  // new settings at the end
    #expect(lines.contains("save_audio = false") && lines.contains("token_file = \"~/.config/memoir/token\""))
    #expect(lines.filter { $0.hasPrefix("save_dir") }.count == 1)
    #expect(MemoirConfig.load(path: path) == config)
}
