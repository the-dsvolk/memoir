import Foundation

/// One step of the after-the-call pipeline (DESIGN.md §4.8): a command run on this Mac against a
/// finished call folder, e.g. "summarize it" or "turn the summary into a Google Doc".
public struct PipelineStep: Sendable, Equatable, Identifiable {
    public var id: String
    /// Shown in the app: "Summary", "Google Doc".
    public var label: String
    /// argv; `{call}`, `{folder}`, `{name}` and `{date}` are filled in, a leading `~/` is expanded.
    public var run: [String]
    /// Working directory (default: the call folder).
    public var cwd: String?
    /// Steps that must have succeeded first.
    public var needs: [String] = []
    /// Files (relative to the call folder) the step must write; checked after it exits.
    public var outputs: [String] = []
    /// Extra environment variables.
    public var env: [String: String] = [:]
    /// Environment variables read from the login Keychain: VAR = service, for your user account
    /// (`security find-generic-password -a "$USER" -s <service> -w`).
    public var keychain: [String: String] = [:]
    public var timeout: TimeInterval = 1800
    /// Sends the call's content off this Mac (a cloud model, Google Drive…). Off for "Keep local only".
    public var remote = true
    /// Ticked by default in New Call.
    public var enabledByDefault = true

    public init(id: String, label: String? = nil, run: [String]) {
        self.id = id
        self.label = label ?? id
        self.run = run
    }
}

/// `~/.config/memoir/pipeline.toml`: the steps to run after a call, shared by Memoir.app and
/// `memoir process` (DESIGN.md §4.8).
public struct PipelineConfig: Sendable, Equatable {
    public static let defaultPath = "~/.config/memoir/pipeline.toml"

    /// In dependency order (`needs` first), otherwise as written.
    public private(set) var steps: [PipelineStep]
    /// Calls with fewer finished lines than this aren't processed automatically.
    public var minFinals = 5
    /// Run steps through your login shell (`$SHELL -l`), so they get the same PATH and settings as
    /// Terminal — an app started by macOS doesn't read your shell profile otherwise.
    public var loginShell = true

    public init(steps: [PipelineStep]) throws {
        self.steps = try Self.ordered(steps)
    }

    /// The pipeline at `path`, or nil if there is no such file.
    public static func load(path: String = defaultPath) throws -> PipelineConfig? {
        let url = URL(fileURLWithPath: MemoirConfig.expand(path))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try parse(String(contentsOf: url, encoding: .utf8))
        } catch let error as PipelineConfigError {
            throw error
        } catch {
            throw PipelineConfigError("\((url.path as NSString).abbreviatingWithTildeInPath): \(error)")
        }
    }

    public static func parse(_ text: String) throws -> PipelineConfig {
        let doc = try TOML.parse(text)
        try checkKeys(doc, allowed: ["min_finals", "login_shell", "step"], in: "the file")
        var steps: [PipelineStep] = []
        for (n, value) in (doc["step"]?.array ?? []).enumerated() {
            guard let table = value.table else { throw PipelineConfigError("step \(n + 1) is not a table") }
            steps.append(try step(table, number: n + 1))
        }
        var config = try PipelineConfig(steps: steps)
        if let v = doc["min_finals"] {
            guard let n = v.integer, n >= 0 else { throw PipelineConfigError("min_finals must be a whole number") }
            config.minFinals = n
        }
        if let v = doc["login_shell"] {
            guard let b = v.bool else { throw PipelineConfigError("login_shell must be true or false") }
            config.loginShell = b
        }
        return config
    }

    public func step(_ id: String) -> PipelineStep? { steps.first { $0.id == id } }

    /// The steps ticked by default (minus remote ones for a "Keep local only" call), with what they need.
    public func defaultSteps(keepLocal: Bool = false) -> [String] {
        selection(steps.filter(\.enabledByDefault).map(\.id), keepLocal: keepLocal)
    }

    /// `ids` plus everything they need, in run order; with `keepLocal`, remote steps (and steps that
    /// need them) are dropped.
    public func selection(_ ids: [String], keepLocal: Bool = false) -> [String] {
        var chosen = Set<String>()
        func add(_ id: String) {
            guard let step = step(id), !chosen.contains(id) else { return }
            chosen.insert(id)
            step.needs.forEach(add)
        }
        ids.forEach(add)
        if keepLocal {
            var changed = true
            while changed {  // drop remote steps, then anything left needing a dropped step
                changed = false
                for step in steps where chosen.contains(step.id)
                    && (step.remote || step.needs.contains { !chosen.contains($0) }) {
                    chosen.remove(step.id)
                    changed = true
                }
            }
        }
        return steps.map(\.id).filter(chosen.contains)
    }

    /// Steps that need `id`, directly or not.
    public func dependents(of id: String) -> [String] {
        var out = Set<String>()
        var changed = true
        while changed {
            changed = false
            for step in steps where !out.contains(step.id) && step.needs.contains(where: { $0 == id || out.contains($0) }) {
                out.insert(step.id)
                changed = true
            }
        }
        return steps.map(\.id).filter(out.contains)
    }

    // MARK: - Parsing

    private static func step(_ t: [String: TOMLValue], number: Int) throws -> PipelineStep {
        let name = t["id"]?.string ?? "step \(number)"
        try checkKeys(t, allowed: ["id", "label", "run", "cwd", "needs", "outputs", "env", "keychain", "timeout",
                                   "remote", "default"], in: name)
        guard let id = t["id"]?.string, !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw PipelineConfigError("\(name): id must be letters, digits, - or _")
        }
        let run = try strings(t["run"], "run", in: id)
        guard !run.isEmpty else { throw PipelineConfigError("\(id): run needs a command") }
        var step = PipelineStep(id: id, label: try t["label"].map { try string($0, "label", in: id) }, run: run)
        step.cwd = try t["cwd"].map { try string($0, "cwd", in: id) }
        step.needs = try strings(t["needs"], "needs", in: id)
        step.outputs = try strings(t["outputs"], "outputs", in: id)
        step.env = try stringTable(t["env"], "env", in: id)
        step.keychain = try stringTable(t["keychain"], "keychain", in: id)
        if let v = t["timeout"] {
            guard let s = v.integer, s > 0 else { throw PipelineConfigError("\(id): timeout must be seconds") }
            step.timeout = TimeInterval(s)
        }
        if let v = t["remote"] {
            guard let b = v.bool else { throw PipelineConfigError("\(id): remote must be true or false") }
            step.remote = b
        }
        if let v = t["default"] {
            guard let b = v.bool else { throw PipelineConfigError("\(id): default must be true or false") }
            step.enabledByDefault = b
        }
        return step
    }

    /// Dependency order, stable otherwise; rejects duplicate ids, unknown `needs` and cycles.
    private static func ordered(_ steps: [PipelineStep]) throws -> [PipelineStep] {
        var ids = Set<String>()
        for step in steps {
            guard ids.insert(step.id).inserted else { throw PipelineConfigError("two steps are called \(step.id)") }
        }
        for step in steps {
            for need in step.needs where !ids.contains(need) {
                throw PipelineConfigError("\(step.id) needs \(need), which isn't a step")
            }
        }
        var out: [PipelineStep] = []
        var done = Set<String>()
        while out.count < steps.count {
            guard let next = steps.first(where: { !done.contains($0.id) && $0.needs.allSatisfy(done.contains) }) else {
                let left = steps.filter { !done.contains($0.id) }.map(\.id).joined(separator: ", ")
                throw PipelineConfigError("steps need each other in a loop: \(left)")
            }
            out.append(next)
            done.insert(next.id)
        }
        return out
    }

    private static func checkKeys(_ t: [String: TOMLValue], allowed: Set<String>, in place: String) throws {
        if let unknown = t.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw PipelineConfigError("unknown setting \(unknown) in \(place)")
        }
    }

    private static func string(_ v: TOMLValue, _ key: String, in id: String) throws -> String {
        guard let s = v.string else { throw PipelineConfigError("\(id): \(key) must be a string") }
        return s
    }

    private static func strings(_ v: TOMLValue?, _ key: String, in id: String) throws -> [String] {
        guard let v else { return [] }
        guard let items = v.array?.compactMap(\.string), items.count == v.array?.count else {
            throw PipelineConfigError("\(id): \(key) must be a list of strings")
        }
        return items
    }

    private static func stringTable(_ v: TOMLValue?, _ key: String, in id: String) throws -> [String: String] {
        guard let v else { return [:] }
        guard let t = v.table else { throw PipelineConfigError("\(id): \(key) must be a table") }
        return try t.mapValues { try string($0, "\(key) values", in: id) }
    }
}

/// `42 s`, `2 min 3 s`, `1 h 5 min`.
public func durationText(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
    return "\(s / 3600) h \(s / 60 % 60) min"
}

public struct PipelineConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What to do after a call, chosen when it starts (New Call / `listen`) and kept in `meeting.json`.
public struct PostprocessChoice: Sendable, Equatable {
    public var steps: [String]
    /// Nothing from this call may leave the Mac: remote steps are off.
    public var keepLocal: Bool

    public init(steps: [String], keepLocal: Bool = false) {
        self.steps = steps
        self.keepLocal = keepLocal
    }

    var json: [String: Any] { ["steps": steps, "keep_local": keepLocal] }
}

/// A recorded call, read back from its folder (`meeting.json`, `transcript.txt`).
public struct CallInfo: Sendable, Equatable, Identifiable {
    public let folder: URL
    public var name: String
    public var startedAt: Date?
    public var endedAt: Date?
    /// Chosen when the call started; nil for calls recorded before the pipeline existed.
    public var postprocess: PostprocessChoice?
    /// Finished lines in `transcript.txt`.
    public var finals: Int

    public var id: String { folder.path }
    /// The name, or the folder's if the call has none.
    public var title: String { name.isEmpty ? folder.lastPathComponent : name }

    /// `2026-10-18`: the call's day (from the folder name if `meeting.json` has no start time).
    public var day: String {
        guard let startedAt else { return String(folder.lastPathComponent.prefix(10)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: startedAt)
    }

    public static func load(_ folder: URL) throws -> CallInfo {
        let data = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let iso = ISO8601DateFormatter()
        var choice: PostprocessChoice?
        if let p = json["postprocess"] as? [String: Any] {
            choice = PostprocessChoice(steps: p["steps"] as? [String] ?? [], keepLocal: p["keep_local"] as? Bool ?? false)
        }
        let transcript = (try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
        return CallInfo(folder: folder, name: json["name"] as? String ?? "",
                        startedAt: (json["started_at"] as? String).flatMap(iso.date),
                        endedAt: (json["ended_at"] as? String).flatMap(iso.date),
                        postprocess: choice,
                        finals: transcript.split(whereSeparator: \.isNewline).count)
    }

    /// The latest calls in `saveDir`, newest first.
    public static func recent(in saveDir: URL, limit: Int = 10) -> [CallInfo] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        let calls = folders.compactMap { try? load($0) }
        return Array(calls.sorted {
            ($0.startedAt ?? .distantPast, $0.folder.lastPathComponent) > ($1.startedAt ?? .distantPast, $1.folder.lastPathComponent)
        }.prefix(limit))
    }
}
