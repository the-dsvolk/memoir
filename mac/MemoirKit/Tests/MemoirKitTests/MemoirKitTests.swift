import AVFoundation
import Foundation
import Testing
@testable import MemoirKit

@Test func audioFrameHeader() {
    let data = Wire.audioFrame(source: .them, sampleOffset: 0x01_0203_0405, samples: [1, -2])
    #expect(data.count == Wire.headerSize + 4)
    #expect(Array(data.prefix(12)) == [1, 0, 0, 0, 0x05, 0x04, 0x03, 0x02, 0x01, 0, 0, 0])
    #expect(Array(data.suffix(4)) == [1, 0, 0xFE, 0xFF])
}

@Test func framerCutsAndFlushes() {
    var framer = Framer(frameSamples: 4)
    #expect(framer.push([1, 2, 3]).isEmpty)
    #expect(framer.push([4, 5, 6, 7, 8, 9]) == [.init(offset: 0, samples: [1, 2, 3, 4]), .init(offset: 4, samples: [5, 6, 7, 8])])
    #expect(framer.flush() == .init(offset: 8, samples: [9]))
    #expect(framer.flush() == nil)
    #expect(framer.nextOffset == 9)
}

@Test func wavHeader() {
    let header = WAVWriter.header(dataBytes: 3200)
    #expect(header.count == 44)
    #expect(String(decoding: header.prefix(4), as: UTF8.self) == "RIFF")
    #expect(Array(header[22 ..< 28]) == [1, 0, 0x80, 0x3E, 0, 0])  // mono, 16000 Hz
    #expect(Array(header[40 ..< 44]) == [0x80, 0x0C, 0, 0])  // 3200 data bytes
}

@Test func startMessageKeys() throws {
    let json = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(StartMessage(meetingId: "m1", title: "t", sources: [.me]))) as? [String: Any]
    #expect(json?["type"] as? String == "start")
    #expect(json?["meeting_id"] as? String == "m1")
    #expect(json?["sample_rate"] as? Int == 16000)
    #expect(json?["sources"] as? [String] == ["me"])
}

@Test func converterResamples48kStereoTo16kMono() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let frames: AVAudioFrameCount = 4800  // 100 ms
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0 ..< 2 {
        for i in 0 ..< Int(frames) { buffer.floatChannelData![ch][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48_000) }
    }
    let converter = try PCMConverter(inputFormat: format)
    var total = 0
    var peak: Int16 = 0
    var shortfalls: [Int] = []  // expected minus produced, after each second
    for call in 1 ... 100 {  // 10 s of audio, 100 ms per call
        let out = converter.convert(buffer)
        total += out.count
        peak = max(peak, out.map { $0.magnitude }.max().map(Int16.init) ?? 0)
        if call % 10 == 0 { shortfalls.append(call * 1600 - total) }
    }
    #expect(shortfalls.allSatisfy { $0 >= 0 && $0 < 400 }, "shortfall per second: \(shortfalls)")
    #expect(peak > 10_000)  // ~0.5 full scale
}

@Test func liveTranscriptHoldsFinalForLatePunctuation() {
    var t = LiveTranscript()
    #expect(t.handle(.init(type: "partial", seg: 0, text: "can we")) == [.live("can we")])
    #expect(t.handle(.init(type: "final", seg: 0, text: "Can we go", t0: 1)) == [.live("Can we go")])
    #expect(t.handle(.init(type: "partial", seg: 1, text: "")) == [])  // keep showing the final
    #expect(t.handle(.init(type: "final", seg: 0, text: "Can we go?", t0: 1)) == [.live("Can we go?")])
    #expect(t.handle(.init(type: "partial", seg: 1, text: "Sure")) == [.line("[00:01] Can we go?"), .live("Sure")])
    #expect(t.handle(.init(type: "final", seg: 0, text: "late amend")) == [])  // already committed
    #expect(t.handle(.init(type: "final", seg: 1, text: "Sure.", t0: 65)) == [.live("Sure.")])
    #expect(t.finish() == [.line("[01:05] Sure.")])
}

@Test func liveTranscriptLabelsSourcesAndKeepsOrder() {
    var t = LiveTranscript(labelled: true)
    #expect(t.handle(.init(type: "final", source: "them", seg: 0, text: "Hi all", t0: 1)) == [.live("Them: Hi all")])
    // The other side starts talking: Them's held sentence is committed first, then Me goes live.
    #expect(t.handle(.init(type: "partial", source: "me", seg: 0, text: "hello"))
        == [.line("[00:01] Them: Hi all"), .live("Me: hello")])
    #expect(t.handle(.init(type: "final", source: "them", seg: 0, text: "Hi all.")) == [])  // too late, ignored
    #expect(t.handle(.init(type: "final", source: "me", seg: 0, text: "Hello.", t0: 3)) == [.live("Me: Hello.")])
    #expect(t.finish() == [.line("[00:03] Me: Hello.")])
}
