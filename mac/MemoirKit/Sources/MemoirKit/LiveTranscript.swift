/// Turns server messages into terminal output: a live line that keeps changing, and committed lines.
///
/// Tracked per source. The newest final of a source is held on the live line until that source starts
/// its next sentence, because the server may re-send it (same `seg`) with punctuation that arrived
/// late. Activity from another source commits it at once, so lines stay in time order. Amendments to
/// lines already committed can't be shown in a terminal and are ignored here (the server's JSONL has
/// them). With several sources, lines and the live text are labelled "Me:" / "Them:".
public struct LiveTranscript: Sendable {
    public enum Output: Equatable, Sendable {
        case live(String)  // replace the current in-place line
        case line(String)  // print as a finished line
    }

    private struct Pending: Sendable {
        let seg: Int
        var text: String
        let t0: Double
    }

    private var pending: [String: Pending] = [:]
    private var lastCommitted: [String: Int] = [:]
    private let labelled: Bool

    public init(labelled: Bool = false) {
        self.labelled = labelled
    }

    public mutating func handle(_ msg: ServerMessage) -> [Output] {
        guard let seg = msg.seg, let text = msg.text, msg.type == "final" || msg.type == "partial" else { return [] }
        let source = msg.source ?? "me"
        var out: [Output] = []
        if !text.isEmpty {
            for other in pending.keys.sorted() where other != source { out += commit(other) }
        }
        if msg.type == "final" {
            if seg <= lastCommitted[source, default: -1] { return out }
            if var p = pending[source], p.seg == seg {
                p.text = text
                pending[source] = p
                return out + [live(source, text)]
            }
            out += commit(source)
            pending[source] = Pending(seg: seg, text: text, t0: msg.t0 ?? 0)
            out.append(live(source, text))
        } else {
            if let p = pending[source], seg > p.seg, !text.isEmpty { out += commit(source) }
            if pending[source] == nil { out.append(live(source, text)) }
        }
        return out
    }

    /// Commits whatever is still pending (call when the stream ends).
    public mutating func finish() -> [Output] {
        var out: [Output] = []
        for source in pending.sorted(by: { $0.value.t0 < $1.value.t0 }).map(\.key) {
            out += commit(source)
        }
        return out
    }

    private mutating func commit(_ source: String) -> [Output] {
        guard let p = pending.removeValue(forKey: source) else { return [] }
        lastCommitted[source] = p.seg
        return [.line("[\(Self.clock(p.t0))] \(label(source))\(p.text)")]
    }

    private func live(_ source: String, _ text: String) -> Output {
        .live(text.isEmpty ? "" : label(source) + text)
    }

    private func label(_ source: String) -> String {
        labelled ? source.prefix(1).uppercased() + source.dropFirst() + ": " : ""
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
