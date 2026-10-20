import Foundation
import Testing
@testable import MemoirKit

/// Speech-like test signals: noise with a syllable-rate envelope, deterministic.
private func speech(seconds: Double, rms: Double, seed: UInt64) -> [Double] {
    var state = seed
    let n = Int(seconds * 16000)
    return (0 ..< n).map { i in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let white = Double(Int64(bitPattern: state >> 1) % 20000) / 10000 - 1  // -1…1
        let envelope = 0.6 + 0.4 * sin(Double(i) / 16000 * 2 * .pi * 4)  // 4 Hz "syllables"
        return white * envelope * rms * 1.9
    }
}

private func pcm(_ x: [Double]) -> [Int16] { x.map { Int16(max(-32767, min(32767, $0 * 32767))) } }

private func delayed(_ x: [Double], by seconds: Double) -> [Double] {
    let d = Int(seconds * 16000)
    return [Double](repeating: 0, count: d) + x.prefix(x.count - d)
}

private func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { $0 + $1 } }

private func silence(_ seconds: Double) -> [Double] { [Double](repeating: 0, count: Int(seconds * 16000)) }

/// Feeds both streams as the captures would — Them in 10 ms buffers, the mic in 85 ms ones, Them up to
/// the end of each mic buffer first — and returns the gated mic.
private func run(_ gate: EchoGate, far: [Int16], near: [Int16], start: Double = 1000) -> [Int16] {
    var out: [Int16] = []
    var farAt = 0
    var nearAt = 0
    while nearAt < near.count {
        let nearEnd = min(nearAt + 1360, near.count)
        while farAt < min(nearEnd, far.count) {
            let end = min(farAt + 160, far.count)
            gate.far(Array(far[farAt ..< end]), at: start + Double(farAt) / 16000)
            farAt = end
        }
        out += gate.near(Array(near[nearAt ..< nearEnd]), at: start + Double(nearAt) / 16000)
        nearAt = nearEnd
    }
    return out
}

private func energy(_ x: [Int16], from: Double, to: Double) -> Double {
    EchoGate.energy(x[Int(from * 16000) ..< Int(to * 16000)])
}

@Test func echoGateSilencesTheLeak() {
    let them = speech(seconds: 4, rms: 0.2, seed: 1)
    let leak = delayed(them, by: 0.03).map { $0 * 0.02 }  // -34 dB, 30 ms later
    let gate = EchoGate()
    let out = run(gate, far: pcm(them), near: pcm(leak))
    #expect(energy(out, from: 0.5, to: 4) < energy(pcm(leak), from: 0.5, to: 4) * 0.01)
    #expect(gate.stats.gatedSeconds > 3.3)
    #expect(gate.stats.leakDb.map { $0 < -25 } == true)
}

@Test func echoGateLetsMyVoiceThroughOverThem() {
    let them = speech(seconds: 4, rms: 0.2, seed: 2)
    let leak = delayed(them, by: 0.03).map { $0 * 0.02 }
    let me = silence(1) + speech(seconds: 2, rms: 0.08, seed: 3) + silence(1)  // I talk over them, 1–3 s
    let mic = pcm(mix(leak, me))
    let out = run(EchoGate(), far: pcm(them), near: mic)
    #expect(energy(out, from: 1.1, to: 2.9) > energy(mic, from: 1.1, to: 2.9) * 0.95)
    #expect(energy(out, from: 3.2, to: 4) < energy(mic, from: 3.2, to: 4) * 0.05)  // then the leak again
}

@Test func echoGateLeavesTheMicAloneWhenNothingPlays() {
    let mic = pcm(speech(seconds: 2, rms: 0.01, seed: 4))
    #expect(run(EchoGate(), far: pcm(silence(2)), near: mic) == mic)
}

@Test func echoGateCoversBluetoothDelay() {
    let them = speech(seconds: 4, rms: 0.2, seed: 5)
    let leak = delayed(them, by: 0.3).map { $0 * 0.02 }  // AirPods-like latency
    let out = run(EchoGate(), far: pcm(them), near: pcm(leak))
    #expect(energy(out, from: 0.8, to: 4) < energy(pcm(leak), from: 0.8, to: 4) * 0.02)
}

@Test func echoGateCannotBeTaughtToMuteMe() {
    // Cross-talk all call long: I talk over Them 80 % of the time, so mic/Them looks like my voice.
    let them = speech(seconds: 10, rms: 0.2, seed: 6)
    let leak = delayed(them, by: 0.03).map { $0 * 0.02 }
    let me = speech(seconds: 8, rms: 0.08, seed: 7) + silence(2)
    let mic = pcm(mix(leak, me))
    let gate = EchoGate()
    let out = run(gate, far: pcm(them), near: mic)
    #expect(gate.stats.leakDb.map { $0 <= -25 + 0.01 } == true)  // capped
    #expect(energy(out, from: 3, to: 7.9) > energy(mic, from: 3, to: 7.9) * 0.95)
}
