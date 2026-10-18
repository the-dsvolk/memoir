/// Turns server messages into terminal output: a live line that keeps changing, and committed lines.
///
/// The newest final is held on the live line until the next sentence starts, because the server may
/// re-send it (same `seg`) with punctuation that arrived late. Amendments to lines already committed
/// can't be shown in a terminal and are ignored here (the server's JSONL has them).
public struct LiveTranscript: Sendable {
    public enum Output: Equatable, Sendable {
        case live(String)  // replace the current in-place line
        case line(String)  // print as a finished line
    }

    private var pending: (seg: Int, text: String, t0: Double)?
    private var lastCommitted = -1

    public init() {}

    public mutating func handle(_ msg: ServerMessage) -> [Output] {
        guard let seg = msg.seg, let text = msg.text else { return [] }
        switch msg.type {
        case "final":
            if seg <= lastCommitted { return [] }
            if let p = pending, p.seg == seg {
                pending = (seg, text, p.t0)
                return [.live(text)]
            }
            var out = commit()
            pending = (seg, text, msg.t0 ?? 0)
            out.append(.live(text))
            return out
        case "partial":
            var out: [Output] = []
            if let p = pending, seg > p.seg, !text.isEmpty {
                out = commit()
            }
            if pending == nil { out.append(.live(text)) }
            return out
        default:
            return []
        }
    }

    /// Commits whatever is still pending (call when the stream ends).
    public mutating func finish() -> [Output] { commit() }

    private mutating func commit() -> [Output] {
        guard let p = pending else { return [] }
        pending = nil
        lastCommitted = p.seg
        return [.line("[\(Self.clock(p.t0))] \(p.text)")]
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
