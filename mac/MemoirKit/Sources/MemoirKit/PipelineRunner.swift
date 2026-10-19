import Foundation

/// Where one step stands for one call.
public struct StepState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, running, ok, failed, skipped, cancelled }

    public var status: Status
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    /// Why it failed, was skipped or cancelled.
    public var message: String?
    /// A link the step printed as its last line — e.g. the new Google Doc.
    public var url: String?
    /// The files it wrote, relative to the call folder.
    public var outputs: [String]?

    public init(status: Status, startedAt: Date? = nil, message: String? = nil) {
        self.status = status
        self.startedAt = startedAt
        self.message = message
    }

    public var isActive: Bool { status == .pending || status == .running }
}

/// The pipeline's record in a call folder: `pipeline/state.json`, plus one log per step
/// (`pipeline/<step>.log`). The raw call files are never touched by the runner.
public struct PipelineState: Codable, Sendable, Equatable {
    public var steps: [String: StepState] = [:]
    public var updatedAt: Date?

    public init() {}

    public var isActive: Bool { steps.values.contains(where: \.isActive) }

    public static func directory(_ call: URL) -> URL { call.appendingPathComponent("pipeline", isDirectory: true) }
    public static func log(_ call: URL, step: String) -> URL { directory(call).appendingPathComponent("\(step).log") }

    /// The saved state; a step left running by a process that's gone shows as cancelled ("interrupted").
    public static func load(_ call: URL) -> PipelineState? {
        guard var state = read(call) else { return nil }
        if !PipelineRunner.isBusy(call) { state.markInterrupted() }
        return state
    }

    static func read(_ call: URL) -> PipelineState? {
        guard let data = try? Data(contentsOf: directory(call).appendingPathComponent("state.json")) else { return nil }
        return try? decoder.decode(PipelineState.self, from: data)
    }

    func save(_ call: URL) throws {
        let url = Self.directory(call).appendingPathComponent("state.json")
        try Self.encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// This state as `state.json` holds it (times to the millisecond).
    var saved: PipelineState {
        (try? Self.encoder.encode(self)).flatMap { try? Self.decoder.decode(PipelineState.self, from: $0) } ?? self
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = isoFormatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
            }
            return date
        }
        return decoder
    }

    /// `2026-10-18T14:30:05.123-07:00`, in local time like `meeting.json`.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    mutating func markInterrupted() {
        for (id, step) in steps where step.isActive {
            steps[id]?.status = .cancelled
            steps[id]?.message = "interrupted"
        }
    }
}

public struct PipelineError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Runs pipeline steps on one finished call (DESIGN.md §4.8) — used by Memoir.app and `memoir process`.
/// Each step is its own process group, so cancelling or a timeout stops everything it started.
public final class PipelineRunner: @unchecked Sendable {
    public let config: PipelineConfig
    public let call: URL
    /// Each step's output as it arrives (the CLI's `--verbose`).
    public var onOutput: (@Sendable (_ step: String, _ data: Data) -> Void)?

    private let lock = NSLock()
    private var cancelled = false
    private var child: pid_t = 0
    private var tracked: StepProcesses?

    public init(config: PipelineConfig, call: URL) {
        self.config = config
        self.call = call
    }

    /// Another runner (the app or the CLI) is working on this call.
    public static func isBusy(_ call: URL) -> Bool {
        let path = PipelineState.directory(call).appendingPathComponent(".lock").path
        let fd = open(path, O_RDONLY | O_SHLOCK | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { close(fd); return false }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    /// Stops the running step (SIGTERM to its process group, SIGKILL 5 s later) and skips the rest.
    public func cancel() {
        lock.withLock {
            cancelled = true
            if child > 0 { terminate(child) }
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs `requested` on the call, plus whatever they need that hasn't succeeded yet. Steps that
    /// already succeeded are kept unless `force`. Every change is saved and passed to `onChange`.
    @discardableResult
    public func run(steps requested: [String], force: Bool = false,
                    onChange: @escaping @Sendable (PipelineState) -> Void = { _ in }) async throws -> PipelineState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: call.appendingPathComponent("meeting.json").path) else {
            throw PipelineError("\(call.path) is not a call folder (no meeting.json)")
        }
        if let unknown = requested.first(where: { config.step($0) == nil }) {
            throw PipelineError("there is no step \(unknown) in the pipeline")
        }
        let dir = PipelineState.directory(call)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = open(dir.appendingPathComponent(".lock").path,
                          O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw PipelineError("this call is already being processed") }
        defer { close(lockFD) }

        var state = PipelineState.read(call) ?? PipelineState()
        state.markInterrupted()  // we hold the lock: nothing else is running on this call

        // A step runs if it was asked for with `force`, hasn't succeeded (or its outputs are gone), or
        // something it needs has to run again; otherwise its earlier result stands.
        var plan: [String: Bool] = [:]
        func mustRun(_ id: String) -> Bool {
            if let known = plan[id] { return known }
            let step = config.step(id)
            let needs = (step?.needs ?? []).map(mustRun)  // visit them all, so each gets a verdict
            let run = (force && requested.contains(id)) || !succeeded(id, in: state) || needs.contains(true)
            plan[id] = run
            return run
        }
        requested.forEach { _ = mustRun($0) }
        let order = config.steps.filter { plan[$0.id] == true }

        func update() {
            state.updatedAt = Date()
            try? state.save(call)
            state = state.saved  // the same precision as state.json, so a reload compares equal
            onChange(state)
        }
        for step in order { state.steps[step.id] = StepState(status: .pending) }
        update()

        for step in order {
            if isCancelled {
                state.steps[step.id] = StepState(status: .cancelled, message: "cancelled")
            } else if let need = step.needs.first(where: { state.steps[$0]?.status != .ok }) {
                state.steps[step.id] = StepState(status: .skipped,
                                                 message: "needs \(config.step(need)?.label ?? need), which didn't finish")
            } else {
                state.steps[step.id] = StepState(status: .running, startedAt: Date())
                update()
                state.steps[step.id] = await execute(step)
            }
            update()
        }
        return state
    }

    /// Succeeded before, and its outputs are still there.
    private func succeeded(_ id: String, in state: PipelineState) -> Bool {
        guard state.steps[id]?.status == .ok, let step = config.step(id) else { return false }
        return step.outputs.allSatisfy { FileManager.default.fileExists(atPath: call.appendingPathComponent($0).path) }
    }

    // MARK: - One step

    private func execute(_ step: PipelineStep) async -> StepState {
        let started = Date()
        var result = StepState(status: .running, startedAt: started)
        do {
            let info = try? CallInfo.load(call)
            let argv = step.run.map { fill($0, info) }
            let cwd = step.cwd.map { fill($0, info) } ?? call.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                throw PipelineError("no folder \(cwd)")
            }
            var env = ProcessInfo.processInfo.environment
            env["MEMOIR_CALL_DIR"] = call.path
            env["MEMOIR_STEP"] = step.id
            for (key, value) in step.env { env[key] = fill(value, info) }
            for (key, service) in step.keychain { env[key] = try Keychain.password(service: service) }

            var command = argv
            if config.loginShell {
                // `exec "$@"`: the shell loads your profile (PATH…), then becomes the command itself.
                command = [Self.loginShell, "-l", "-c", "exec \"$@\"", "memoir-\(step.id)"] + argv
            } else {
                command[0] = try Self.resolve(argv[0], path: env["PATH"] ?? "/usr/bin:/bin")
            }

            let logURL = PipelineState.log(call, step: step.id)
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL)
            let header = "# \(ISO8601DateFormatter().string(from: started)) memoir step \(step.id)\n# cwd: \(cwd)\n"
                + "# run: \(argv.joined(separator: " "))\n\n"
            try log.write(contentsOf: Data(header.utf8))
            let sink = OutputSink(log: log, step: step.id, onOutput: onOutput)
            let exit = try await spawn(command, cwd: cwd, env: env, sink: sink, timeout: step.timeout)
            try? log.close()

            result.finishedAt = Date()
            result.exitCode = exit.code
            let last = sink.lastLine
            if exit.cancelled {
                result.status = .cancelled
                result.message = "cancelled"
            } else if exit.timedOut {
                result.status = .failed
                result.message = "timed out after \(durationText(step.timeout))"
            } else if exit.code != 0 {
                result.status = .failed
                result.message = last.map { "\($0) (exit \(exit.code))" } ?? "exit code \(exit.code)"
            } else {
                let missing = step.outputs.filter { !written($0, since: started) }
                if missing.isEmpty {
                    result.status = .ok
                    result.outputs = step.outputs
                    if let last, last.hasPrefix("https://") || last.hasPrefix("http://"), !last.contains(" ") {
                        result.url = last
                    }
                } else {
                    result.status = .failed
                    result.message = "finished without writing \(missing.joined(separator: ", "))"
                }
            }
        } catch {
            result.status = .failed
            result.finishedAt = Date()
            result.message = "\(error)"
        }
        return result
    }

    /// The output exists and was (re)written by this run — not left over from an earlier one.
    private func written(_ output: String, since started: Date) -> Bool {
        let path = call.appendingPathComponent(output).path
        guard let modified = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
            return false
        }
        return modified >= started.addingTimeInterval(-1)
    }

    /// `{call}`, `{folder}`, `{name}`, `{date}`; then a leading `~/`.
    private func fill(_ text: String, _ info: CallInfo?) -> String {
        let filled = text
            .replacingOccurrences(of: "{call}", with: call.path)
            .replacingOccurrences(of: "{folder}", with: call.lastPathComponent)
            .replacingOccurrences(of: "{name}", with: info?.title ?? call.lastPathComponent)
            .replacingOccurrences(of: "{date}", with: info?.day ?? String(call.lastPathComponent.prefix(10)))
        return filled == "~" || filled.hasPrefix("~/") ? MemoirConfig.expand(filled) : filled
    }

    // MARK: - Processes

    private struct Exit {
        var code: Int32
        var timedOut = false
        var cancelled = false
    }

    private func spawn(_ argv: [String], cwd: String, env: [String: String], sink: OutputSink,
                       timeout: TimeInterval) async throws -> Exit {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw PipelineError("couldn't create a pipe") }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)  // dup2 into the child clears it there

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (so the whole step can be stopped), no other inherited descriptors, and
        // default signal handling (the CLI ignores SIGINT itself; the step shouldn't inherit that).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                               | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGPIPE, SIGHUP, SIGQUIT] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var spawned: pid_t = 0
        let rc = lock.withLock { () -> Int32 in
            guard !cancelled else { return ECANCELED }
            let rc = posix_spawn(&spawned, argv[0], &actions, &attr, cArgs, cEnv)
            if rc == 0 { child = spawned }
            return rc
        }
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            if rc == ECANCELED { return Exit(code: -1, cancelled: true) }
            throw PipelineError("couldn't start \(argv[0]): \(String(cString: strerror(rc)))")
        }
        let pid = spawned  // a constant for the closures below
        let started = StepProcesses(root: pid)
        lock.withLock { tracked = started }
        started.watch()

        let eof = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(readFD, &buffer, buffer.count)
                if n > 0 { sink.append(Data(buffer[0 ..< n])) } else if n < 0, errno == EINTR { continue } else { break }
            }
            close(readFD)
            eof.signal()
        }

        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.child == pid else { return }
                sink.timedOut = true
                self.terminate(pid)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                // The step is over: stop whatever it left running (which may also hold the pipe open).
                started.stopWatching()
                started.stopLeftovers()
                _ = eof.wait(timeout: .now() + 5)
                continuation.resume(returning: status)
            }
        }
        timer.cancel()
        let wasCancelled = lock.withLock { () -> Bool in
            child = 0
            tracked = nil
            return cancelled
        }
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return Exit(code: code, timedOut: sink.timedOut, cancelled: wasCancelled && !sink.timedOut)
    }

    /// Stops the running step: SIGTERM to its process group and to everything it started (which may have
    /// left the group — `uv` gives Python its own), SIGKILL in 5 s if it's still there. Call with `lock` held.
    private func terminate(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        tracked?.signalAll(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if self.child == pid {
                    kill(-pid, SIGKILL)
                    self.tracked?.signalAll(SIGKILL)
                }
            }
        }
    }

    /// Your login shell, from the user database (an app's `SHELL` may not be set).
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, shell.pointee != 0 {
            return String(cString: shell)
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func resolve(_ command: String, path: String) throws -> String {
        if command.contains("/") { return command }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw PipelineError("can't find \(command) on PATH")
    }
}

/// Everything a step started, so what it leaves running can be stopped when it ends. Noted 4× a second
/// while it runs: descendants of its first process — caught while the chain is intact, since an orphan is
/// handed to launchd (the Cursor SDK's bridge outlives Python that way) — and, at the end, anything in
/// their process groups. Start times tell a reused pid apart.
final class StepProcesses: @unchecked Sendable {
    private let root: pid_t
    private let lock = NSLock()
    private var seen: [pid_t: Int] = [:]  // pid → start time (µs)
    private var timer: DispatchSourceTimer?

    init(root: pid_t) { self.root = root }

    func watch() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.note() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stopWatching() {
        lock.withLock { timer?.cancel() }
    }

    /// Adds the root's new descendants.
    func note() {
        let table = ProcessTable.mine()
        lock.withLock {
            var added = true
            while added {
                added = false
                for p in table where seen[p.pid] == nil && (p.ppid == root || seen[p.ppid] != nil) {
                    seen[p.pid] = p.start
                    added = true
                }
            }
        }
    }

    /// Still running: the processes noted, and the members of their process groups and the root's.
    func leftovers() -> [pid_t] {
        let table = ProcessTable.mine()
        let me = getpid(), myGroup = getpgrp()
        return lock.withLock {
            table.filter { p in
                guard p.pid != me, p.pid != root, p.pgid != myGroup else { return false }
                return seen[p.pid] == p.start || p.pgid == root || (seen[p.pgid] != nil && p.pgid != p.pid)
            }.map(\.pid)
        }
    }

    func signalAll(_ signal: Int32) {
        for pid in leftovers() { kill(pid, signal) }
    }

    /// SIGTERM to the leftovers now, SIGKILL 3 s later to any still there.
    func stopLeftovers() {
        let left = leftovers()
        guard !left.isEmpty else { return }
        for pid in left { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in signalAll(SIGKILL) }
    }
}

/// My processes, from the kernel's process table.
enum ProcessTable {
    struct Entry {
        let pid: pid_t
        let ppid: pid_t
        let pgid: pid_t
        let start: Int  // µs since 1970
    }

    static func mine() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { p in
            guard p.kp_proc.p_pid > 0, p.kp_proc.p_stat != SZOMB else { return nil }
            let t = p.kp_proc.p_un.__p_starttime
            return Entry(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, pgid: p.kp_eproc.e_pgid,
                         start: Int(t.tv_sec) * 1_000_000 + Int(t.tv_usec))
        }
    }
}

/// A step's combined stdout/stderr: written to its log, the tail kept for the summary line.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private let log: FileHandle
    private let step: String
    private let onOutput: (@Sendable (String, Data) -> Void)?
    private var tail = Data()
    private var _timedOut = false

    init(log: FileHandle, step: String, onOutput: (@Sendable (String, Data) -> Void)?) {
        self.log = log
        self.step = step
        self.onOutput = onOutput
    }

    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }

    func append(_ data: Data) {
        lock.withLock {
            try? log.write(contentsOf: data)
            tail.append(data)
            if tail.count > 16384 { tail = tail.suffix(8192) }
        }
        onOutput?(step, data)
    }

    /// The last non-empty line, without terminal escape sequences.
    var lastLine: String? {
        let text = lock.withLock { String(decoding: tail, as: UTF8.self) }
        let clean = text
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let line = clean.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
    }
}

/// Passwords from the login Keychain via `security` — the tool you'd use in Terminal, so an item it
/// created opens without a prompt.
enum Keychain {
    static func password(service: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard process.terminationStatus == 0, !password.isEmpty else {
            throw PipelineError("no Keychain password \"\(service)\" for \(NSUserName()) — add it with: "
                                + "security add-generic-password -a \"$USER\" -s \(service) -w")
        }
        return password
    }
}
