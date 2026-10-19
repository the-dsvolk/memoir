import Foundation

/// The transcript as a list of lines for a UI that can edit any line (the app's overlay).
///
/// Lines are keyed by `(source, seg)`: a partial updates its line in place, a final replaces the text
/// and freezes it, a final re-sent with the same `seg` (late punctuation) updates it again, and an
/// empty partial removes a line that never got a final. Ordered by start time.
public struct TranscriptModel: Sendable, Equatable {
    public struct Line: Identifiable, Sendable, Equatable {
        public let source: String
        public let seg: Int
        public var t0: Double
        public var text: String
        public var isFinal: Bool
        public var id: String { "\(source)#\(seg)" }
    }

    public private(set) var lines: [Line] = []

    public init() {}

    public mutating func apply(_ msg: ServerMessage) {
        guard msg.type == "partial" || msg.type == "final", let seg = msg.seg, let text = msg.text else { return }
        let source = msg.source ?? "me"
        let id = "\(source)#\(seg)"
        if let i = lines.firstIndex(where: { $0.id == id }) {
            if msg.type == "final" {
                lines[i].text = text
                lines[i].isFinal = true
                if let t0 = msg.t0 { lines[i].t0 = t0 }
            } else if !lines[i].isFinal {
                if text.isEmpty { lines.remove(at: i) } else { lines[i].text = text }
            }
            return
        }
        guard !text.isEmpty else { return }
        lines.append(Line(source: source, seg: seg, t0: msg.t0 ?? 0, text: text, isFinal: msg.type == "final"))
        lines.sort { ($0.t0, $0.source, $0.seg) < ($1.t0, $1.source, $1.seg) }
    }

    public mutating func clear() { lines.removeAll() }

    /// A recorded call's transcript, read back from its `transcript.jsonl` (a later line with the same
    /// source and `seg` amends the earlier one).
    public static func load(_ folder: URL) -> TranscriptModel {
        var model = TranscriptModel()
        guard let text = try? String(contentsOf: folder.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
        else { return model }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            model.apply(ServerMessage(type: "final", source: json["source"] as? String, seg: json["seg"] as? Int,
                                      text: json["text"] as? String, t0: json["t0"] as? Double))
        }
        return model
    }
}
