import Foundation

/// The record of one call on the Mac (DESIGN.md §4.7, D12): `<save dir>/YYYY-MM-DD_<name>/` with
/// `transcript.jsonl` (raw finals), `transcript.txt` (readable), `prep.md` (material brought to the
/// call), `notes.md` (my notes during it), `meeting.json` and, if asked, one WAV per source. Created at
/// start and written as the call goes, so a crash loses nothing already said. Thread-safe.
public final class MeetingStore: @unchecked Sendable {
    public private(set) var folder: URL
    public private(set) var name: String
    /// Prep written before the call (attendees, agenda, docs…).
    public let prep: String
    public let startedAt: Date
    public let saveAudio: Bool

    private let saveDir: URL
    private let sources: [Source]
    private let client: String
    private let lock = NSLock()
    private var finals: [String: Final] = [:]
    private var quickNotes: [(t: Double, text: String)] = []
    private var prepAdditions: [(t: Double, text: String)] = []
    private var jsonl: FileHandle?
    private var audio: [UInt8: WAVWriter] = [:]
    private var details: [String: Any] = [:]

    private struct Final {
        let source: String
        let seg: Int
        let t0: Double
        let text: String
    }

    /// `postprocess`: what to run after the call (DESIGN.md §4.8), kept in `meeting.json`.
    public init(saveDir: URL, name: String, prep: String = "", sources: [Source], client: String,
                saveAudio: Bool = false, postprocess: PostprocessChoice? = nil, startedAt: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.saveDir = saveDir
        self.name = name
        self.prep = prep
        self.sources = sources
        self.client = client
        self.saveAudio = saveAudio
        self.startedAt = startedAt
        if let postprocess { details["postprocess"] = postprocess.json }
        folder = Self.uniqueFolder(in: saveDir, date: startedAt, name: name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let jsonlURL = folder.appendingPathComponent("transcript.jsonl")
        fm.createFile(atPath: jsonlURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        jsonl = try FileHandle(forWritingTo: jsonlURL)
        if saveAudio {
            for source in sources {
                let url = folder.appendingPathComponent("\(source.name).wav")
                audio[source.rawValue] = try WAVWriter(url: url)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        try writeTranscript()
        try writePrep()
        try writeNotes()
        try writeDetails()
    }

    // MARK: - Recording

    /// Appends a `final` to `transcript.jsonl` and regenerates `transcript.txt`. A final re-sent with the
    /// same `seg` (late punctuation) replaces the earlier one in the text file; the JSONL keeps both.
    public func record(final msg: ServerMessage) throws {
        guard msg.type == "final", let seg = msg.seg, let text = msg.text else { return }
        let source = msg.source ?? "me"
        var line: [String: Any] = ["source": source, "seg": seg, "text": text]
        if let t0 = msg.t0 { line["t0"] = t0 }
        if let t1 = msg.t1 { line["t1"] = t1 }
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        try lock.withLock {
            try jsonl?.write(contentsOf: data + Data("\n".utf8))
            finals["\(source)#\(seg)"] = Final(source: source, seg: seg, t0: msg.t0 ?? 0, text: text)
            try writeTranscript()
        }
    }

    public func record(audio samples: [Int16], from source: Source) throws {
        try lock.withLock { try audio[source.rawValue]?.append(samples) }
    }

    /// A quick note typed during the call, stamped with the meeting clock.
    public func addQuickNote(at t: Double, _ text: String) throws {
        try lock.withLock {
            quickNotes.append((t, text))
            try writeNotes()
        }
    }

    /// Prep added during the call (someone joined, a doc was pasted): append-only, stamped with the
    /// meeting clock so post-processing knows when the context changed.
    public func addPrep(at t: Double, _ text: String) throws {
        try lock.withLock {
            prepAdditions.append((t, text))
            try writePrep()
        }
    }

    /// Renames the call; the folder is renamed to match (open files keep working — they follow the inode).
    public func rename(to newName: String) throws {
        try lock.withLock {
            name = newName
            let target = Self.uniqueFolder(in: saveDir, date: startedAt, name: newName, except: folder)
            if target != folder {  // the name maps to a different folder
                try FileManager.default.moveItem(at: folder, to: target)
                folder = target
            }
            try writePrep()
            try writeNotes()
            try writeDetails()
        }
    }

    /// Server details for `meeting.json` (model, chunk size).
    public func setServer(model: String, chunkMs: Int) throws {
        try lock.withLock {
            details["model"] = model
            details["chunk_ms"] = chunkMs
            try writeDetails()
        }
    }

    /// How much of the mic the echo gate silenced, and the leak it learned — in `meeting.json`.
    public func setEchoGate(_ stats: EchoGate.Stats) throws {
        try lock.withLock {
            var gate: [String: Any] = ["gated_s": (stats.gatedSeconds * 10).rounded() / 10,
                                       "mic_s": (stats.micSeconds * 10).rounded() / 10]
            if let leak = stats.leakDb { gate["leak_db"] = (leak * 10).rounded() / 10 }
            details["echo_gate"] = gate
            try writeDetails()
        }
    }

    /// Ends the record: closes the files and stamps `ended_at` (and the server's backup path).
    public func finish(serverPath: String?) throws {
        try lock.withLock {
            details["ended_at"] = Self.iso(Date())
            if let serverPath { details["server_backup"] = serverPath }
            try writeDetails()
            try jsonl?.close()
            jsonl = nil
            for writer in audio.values { try writer.close() }
            audio.removeAll()
        }
    }

    /// For a call that never got going (e.g. the server was unreachable): closes the files and removes
    /// the folder if nothing was recorded in it. Returns true if it was removed.
    @discardableResult
    public func discardIfEmpty() -> Bool {
        lock.withLock {
            guard finals.isEmpty, quickNotes.isEmpty, prepAdditions.isEmpty else { return false }
            try? jsonl?.close()
            jsonl = nil
            for writer in audio.values { try? writer.close() }
            audio.removeAll()
            return (try? FileManager.default.removeItem(at: folder)) != nil
        }
    }

    // MARK: - Files

    private func writeTranscript() throws {
        let lines = finals.values.sorted { ($0.t0, $0.source) < ($1.t0, $1.source) }
            .map { "[\(Self.clock($0.t0))] \(Self.label($0.source)): \($0.text)" }
        try write("transcript.txt", lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }

    /// `notes.md`: my notes during the call, each stamped with the meeting time.
    private func writeNotes() throws {
        var text = "# Notes — \(name)\n\n_\(Self.humanDate(startedAt))_\n\n"
        if quickNotes.isEmpty {
            text += "_(none yet)_\n"
        } else {
            // A multi-line note stays one list item: continuation lines are indented under the bullet.
            text += quickNotes.map { note in
                "- [\(Self.clock(note.t))] "
                    + note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n  ")
            }.joined(separator: "\n") + "\n"
        }
        try write("notes.md", text)
    }

    /// `prep.md`: what was brought to the call — written before it, then appended to during it.
    private func writePrep() throws {
        var text = "# Prep — \(name)\n\n_\(Self.humanDate(startedAt))_\n\n## Before the call\n\n"
        let before = prep.trimmingCharacters(in: .whitespacesAndNewlines)
        text += before.isEmpty ? "_(none)_\n" : before + "\n"
        if !prepAdditions.isEmpty {
            text += "\n## Added during the call\n"
            for addition in prepAdditions {
                text += "\n### \(Self.clock(addition.t))\n\n"
                text += addition.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
        }
        try write("prep.md", text)
    }

    private func writeDetails() throws {
        var json = details
        json["name"] = name
        json["folder"] = folder.lastPathComponent
        json["started_at"] = Self.iso(startedAt)
        json["sources"] = sources.map(\.name)
        json["client"] = client
        json["save_audio"] = saveAudio
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try write("meeting.json", String(decoding: data, as: UTF8.self) + "\n")
    }

    private func write(_ file: String, _ text: String) throws {
        let url = folder.appendingPathComponent(file)
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Naming

    /// `Weekly Sync / Q4` → `weekly-sync-q4`: lowercase letters and digits, everything else becomes `-`.
    public static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `2026-10-18_weekly-sync`; with no usable name, `2026-10-18_untitled-call-1430`.
    public static func folderName(date: Date, name: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let slug = slug(name)
        return "\(day)_\(slug.isEmpty ? String(format: "untitled-call-%02d%02d", c.hour ?? 0, c.minute ?? 0) : slug)"
    }

    /// The folder for `name`, with `_2`, `_3`, … if that name was already used that day.
    static func uniqueFolder(in dir: URL, date: Date, name: String, except current: URL? = nil) -> URL {
        let base = folderName(date: date, name: name)
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while candidate != current, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    static func label(_ source: String) -> String { source.prefix(1).uppercased() + source.dropFirst() }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }
}
