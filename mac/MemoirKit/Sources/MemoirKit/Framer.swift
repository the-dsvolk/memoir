/// Cuts a stream of 16 kHz samples into fixed network frames (100 ms by default), numbering each
/// by the offset of its first sample since the meeting started.
public struct Framer: Sendable {
    public struct Frame: Sendable, Equatable {
        public let offset: UInt64
        public let samples: [Int16]
    }

    public let frameSamples: Int
    public private(set) var nextOffset: UInt64 = 0
    private var pending: [Int16] = []

    public init(frameSamples: Int = Wire.sampleRate / 10) {
        self.frameSamples = frameSamples
    }

    public mutating func push(_ samples: [Int16]) -> [Frame] {
        pending.append(contentsOf: samples)
        var frames: [Frame] = []
        var start = 0
        while pending.count - start >= frameSamples {
            frames.append(Frame(offset: nextOffset, samples: Array(pending[start ..< start + frameSamples])))
            nextOffset += UInt64(frameSamples)
            start += frameSamples
        }
        pending.removeFirst(start)
        return frames
    }

    /// Whatever is left, as a short last frame.
    public mutating func flush() -> Frame? {
        guard !pending.isEmpty else { return nil }
        let frame = Frame(offset: nextOffset, samples: pending)
        nextOffset += UInt64(pending.count)
        pending.removeAll()
        return frame
    }
}
