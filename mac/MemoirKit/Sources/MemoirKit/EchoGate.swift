import Foundation

/// Silences the microphone while all it hears is the call leaking out of the headphones (DESIGN.md §4.3).
///
/// With "Me" and "Them" captured separately, everything the mic picks up is labelled Me — including
/// the other side's voices leaking from headphones into a sensitive mic, which then shows up as a
/// garbled second copy of what Them said. Apple's voice processing can't remove that: its echo
/// canceller only knows the audio its own app plays, and the call is played by Meet / Zoom. memoir has
/// the exact reference instead — the system audio it captures for Them.
///
/// So, in 20 ms blocks: when Them has been playing (within `maxDelay`, which covers output and
/// Bluetooth latency) and the mic is no louder than the learned leak of that audio plus the room's
/// noise, the block becomes silence. My own voice is far louder at the mic than the leak, so it passes,
/// even over Them. The leak level is learned during the call (most of the time Them talks I'm quiet),
/// and capped so a call full of cross-talk can't teach it to mute me.
///
/// Both streams are 16 kHz mono with the host time of their first sample. Thread-safe: the mic and
/// the system-audio callbacks run on different threads.
public final class EchoGate: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        /// Mic audio turned into silence.
        public var gatedSeconds: Double
        /// Mic audio seen.
        public var micSeconds: Double
        /// The learned leak: mic level relative to Them's, in dB (nil until learned).
        public var leakDb: Double?
    }

    public static let farBlock = 160  // 10 ms of Them
    public static let nearBlock = 320  // 20 ms of mic
    static let rate = Double(Wire.sampleRate)

    /// Them counts as playing above this level (mean square of samples in -1…1; ≈ -46 dBFS).
    var farActive = 2.5e-5
    /// How far back Them's audio can still be arriving at the mic: output + Bluetooth latency.
    var maxDelay = 0.4
    /// A mic block within this factor of the expected leak (+ noise) is still leak (≈ 5 dB).
    var margin = 3.0
    /// The leak until enough of the call has been heard to learn it, and the most it may be learned
    /// as (energy ratios: -30 dB and -25 dB). My voice sits 15–30 dB above that at the mic.
    var initialLeak = 1e-3
    var maxLeak = 3e-3
    /// Once the mic carries my voice, it stays open this long — the quiet gaps between my syllables
    /// would otherwise look like leak while Them is loud.
    var hold = 0.25

    private let lock = NSLock()
    private var far: [(time: Double, energy: Double)] = []  // Them's last couple of seconds, per 10 ms
    private var ratios: [Double] = []  // mic / Them while Them plays — the leak, mostly
    private var noises: [Double] = []  // mic level, for the room's noise floor
    private var leak: Double?
    private var noise = 0.0
    private var sinceEstimate = 0
    private var gated = 0
    private var seen = 0
    private var gain = 1.0  // last block's, to ramp between pass and silence without a click
    private var openUntil = -Double.infinity  // the hold after my voice

    public init() {}

    /// Them's audio, as captured (before it reaches the headphones).
    public func far(_ samples: [Int16], at time: Double) {
        lock.withLock {
            var start = 0
            while start < samples.count {
                let end = min(start + Self.farBlock, samples.count)
                far.append((time + Double(start) / Self.rate, Self.energy(samples[start ..< end])))
                start = end
            }
            let keep = (far.last?.time ?? time) - maxDelay - 1
            if let first = far.firstIndex(where: { $0.time >= keep }), first > 0 { far.removeFirst(first) }
        }
    }

    /// The mic's audio, with the blocks that are only leak replaced by silence.
    public func near(_ samples: [Int16], at time: Double) -> [Int16] {
        lock.withLock {
            var out = samples
            var start = 0
            while start < samples.count {
                let end = min(start + Self.nearBlock, samples.count)
                let t = time + Double(start) / Self.rate
                let nearEnergy = Self.energy(samples[start ..< end])
                let farEnergy = loudestFar(from: t - maxDelay, to: t + Double(end - start) / Self.rate + 0.03)
                learn(near: nearEnergy, far: farEnergy)
                let farOn = farEnergy > farActive
                let aboveLeak = nearEnergy >= margin * ((leak ?? initialLeak) * farEnergy + noise)
                // My voice: louder than the leak could be while Them plays, well above the noise otherwise.
                if farOn ? aboveLeak : nearEnergy > 10 * noise + 1e-7 { openUntil = t + hold }
                let isLeak = farOn && !aboveLeak && t >= openUntil
                let target = isLeak ? 0.0 : 1.0
                for i in start ..< end {  // ramp over the first 2.5 ms of a change
                    let step = min(1, Double(i - start) / 40)
                    let g = gain + (target - gain) * step
                    if g < 1 { out[i] = Int16((Double(samples[i]) * g).rounded()) }
                }
                gain = target
                if isLeak { gated += end - start }
                seen += end - start
                start = end
            }
            return out
        }
    }

    public var stats: Stats {
        lock.withLock {
            Stats(gatedSeconds: Double(gated) / Self.rate, micSeconds: Double(seen) / Self.rate,
                  leakDb: leak.map { 10 * log10($0) })
        }
    }

    // MARK: - Inside (lock held)

    private func loudestFar(from: Double, to: Double) -> Double {
        var loudest = 0.0
        for block in far.reversed() {
            if block.time < from { break }
            if block.time <= to { loudest = max(loudest, block.energy) }
        }
        return loudest
    }

    /// Keeps ~30 s of each history and re-estimates twice a second: the leak as the 75th percentile of
    /// mic/Them while Them plays (capped), the noise as the 10th percentile of the mic's level.
    private func learn(near: Double, far: Double) {
        noises.append(near)
        if noises.count > 1500 { noises.removeFirst(noises.count - 1500) }
        if far > farActive {
            ratios.append(near / far)
            if ratios.count > 1500 { ratios.removeFirst(ratios.count - 1500) }
        }
        sinceEstimate += 1
        guard sinceEstimate >= 25 else { return }
        sinceEstimate = 0
        noise = Self.percentile(noises, 0.10)
        if ratios.count >= 100 {  // 2 s of Them playing
            leak = min(maxLeak, max(1e-6, Self.percentile(ratios, 0.75)))
        }
    }

    static func energy(_ block: ArraySlice<Int16>) -> Double {
        guard !block.isEmpty else { return 0 }
        var sum = 0.0
        for s in block {
            let x = Double(s) / 32768
            sum += x * x
        }
        return sum / Double(block.count)
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }
}
