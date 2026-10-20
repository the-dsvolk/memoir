import Foundation
import MemoirKit

let usage = """
    usage: memoir listen [options]
           memoir process <call-folder> [options]

    memoir listen — streams your microphone and/or what the Mac is playing to memoir-asr on the Spark,
    prints the live transcript, and records the call in its own folder: <save dir>/YYYY-MM-DD_<name>/
    (DESIGN.md §4.7). Partial text updates in place on stderr; finished sentences go to stdout. When the
    call ends, the steps in ~/.config/memoir/pipeline.toml run on it (DESIGN.md §4.8).

      --source SRC       mic (default), system (what the Mac plays: YouTube, calls, …), or mic+system
      --name TEXT        the call's name (folder name and title); default untitled-call-HHMM
      --prep TEXT        prep for the call (attendees, agenda, past notes, docs…) → prep.md
      --prep-file PATH   prep read from a file (added after --prep)
      --steps A,B        pipeline steps to run after the call (default: the ones marked default = true)
      --keep-local       nothing from this call leaves the Mac: remote steps are off
      --no-process       don't run the pipeline after the call (memoir process can run it later)
      --no-echo-gate     with mic+system, don't silence the mic while it only hears the call
                         (default from echo_gate in the config, on)
      --out DIR         save folder (default from ~/.config/memoir/config.toml, else ~/memoir)
      --save-audio       also save the audio, one WAV per source, in the call's folder
      --no-record        don't write a call folder (quick tests)
      --input FILE       stream an audio file in real time instead of capturing
      --server URL       server endpoint (default from the config, else ws://spark-0e81.local:8770/v1/stream)
      --token-file PATH  bearer token file (default ~/.config/memoir/token; or set MEMOIR_TOKEN)

    memoir process — runs the pipeline on a recorded call: the steps chosen when it started (else the
    defaults), skipping steps that already succeeded. Links the steps print (e.g. a Google Doc) go to stdout.

      --step ID          run this step (again), plus what it needs; repeat for more
      --force            run the steps again even if they succeeded
      --allow-remote     run remote steps on a call marked keep-local
      --list             show the steps and where this call stands, then exit
      -v, --verbose      show the steps' output as they run

    both:
      --pipeline PATH    pipeline file (default ~/.config/memoir/pipeline.toml)
      -h, --help         show this help

    Settings shared with Memoir.app live in ~/.config/memoir/config.toml.
    Stop with Ctrl-C. With mic+system use headphones, or the mic hears the Mac's audio too.
    """

enum Command {
    case listen(Options)
    case process(ProcessOptions)

    static func parse(_ args: [String]) throws -> Command {
        switch args.first {
        case "listen": .listen(try Options.parse(Array(args.dropFirst())))
        case "process": .process(try ProcessOptions.parse(Array(args.dropFirst())))
        default: throw UsageError()
        }
    }
}

/// Pops flag values off an argument list.
struct Arguments {
    var rest: ArraySlice<String>
    init(_ args: [String]) { rest = args[...] }
    mutating func next() -> String? { rest.popFirst() }
    mutating func value(_ flag: String) throws -> String {
        guard let v = rest.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
        return v
    }
}

struct Options {
    var source = "mic"
    var name = ""
    var prep = ""
    var out: String?
    var saveAudio = false
    var record = true
    var input: URL?
    var server: String?
    var tokenFile: String?
    var steps: [String]?
    var keepLocal = false
    var process = true
    var echoGate = true
    var pipeline = PipelineConfig.defaultPath

    var sources: [Source] {
        if input != nil { return [.me] }
        switch source {
        case "system": return [.them]
        case "mic+system": return [.me, .them]
        default: return [.me]
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var args = Arguments(args)
        while let flag = args.next() {
            switch flag {
            case "--source":
                options.source = try args.value(flag)
                guard ["mic", "system", "mic+system"].contains(options.source) else {
                    throw UsageError(message: "--source must be mic, system or mic+system")
                }
            case "--name", "--title": options.name = try args.value(flag)
            case "--prep":
                options.prep = [options.prep, try args.value(flag)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            case "--prep-file":
                let path = (try args.value(flag) as NSString).expandingTildeInPath
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw UsageError(message: "can't read --prep-file \(path)")
                }
                options.prep = [options.prep, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            case "--steps":
                options.steps = try args.value(flag).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "--keep-local": options.keepLocal = true
            case "--no-process": options.process = false
            case "--no-echo-gate": options.echoGate = false
            case "--pipeline": options.pipeline = try args.value(flag)
            case "--out": options.out = try args.value(flag)
            case "--save-audio": options.saveAudio = true
            case "--no-record": options.record = false
            case "--input": options.input = URL(fileURLWithPath: try args.value(flag))
            case "--server": options.server = try args.value(flag)
            case "--token-file": options.tokenFile = try args.value(flag)
            case "-h", "--help": throw UsageError()
            default: throw UsageError(message: "unknown option \(flag)")
            }
        }
        return options
    }
}

struct ProcessOptions {
    var folder: URL
    var steps: [String] = []
    var force = false
    var allowRemote = false
    var list = false
    var verbose = false
    var pipeline = PipelineConfig.defaultPath

    static func parse(_ args: [String]) throws -> ProcessOptions {
        var folder: String?
        var options = ProcessOptions(folder: URL(fileURLWithPath: "."))
        var args = Arguments(args)
        while let arg = args.next() {
            switch arg {
            case "--step": options.steps.append(try args.value(arg))
            case "--force": options.force = true
            case "--allow-remote": options.allowRemote = true
            case "--list": options.list = true
            case "-v", "--verbose": options.verbose = true
            case "--pipeline": options.pipeline = try args.value(arg)
            case "-h", "--help": throw UsageError()
            default:
                guard !arg.hasPrefix("-"), folder == nil else { throw UsageError(message: "unknown option \(arg)") }
                folder = arg
            }
        }
        guard let folder else { throw UsageError(message: "memoir process needs a call folder") }
        options.folder = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        return options
    }
}

struct UsageError: Error {
    var message: String?
}

enum Terminal {
    static func err(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static var width: Int {
        var size = winsize()
        let tiocgwinsz: UInt = 0x4008_7468  // TIOCGWINSZ on macOS — a C macro Swift doesn't import
        return ioctl(STDERR_FILENO, tiocgwinsz, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 100
    }

    static func render(_ outputs: [LiveTranscript.Output]) {
        for output in outputs {
            switch output {
            case .live(let text):
                let room = max(20, width - 3)
                let shown = text.count > room ? "…" + text.suffix(room - 1) : text
                err("\r\u{1B}[2K\u{1B}[2m\(shown)\u{1B}[0m")
            case .line(let line):
                err("\r\u{1B}[2K")
                print(line)
                fflush(stdout)
            }
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@main
struct MemoirCLI {
    static func main() async {
        do {
            switch try Command.parse(Array(CommandLine.arguments.dropFirst())) {
            case .listen(let options):
                if let call = try await listen(options) { exit(await processAfterCall(call)) }
            case .process(let options):
                exit(try await process(options))
            }
        } catch let error as UsageError {
            if let message = error.message { Terminal.err("memoir: \(message)\n\n") }
            Terminal.err(usage + "\n")
            exit(2)
        } catch {
            Terminal.err("\nmemoir: \(error)\n")
            exit(1)
        }
    }

    /// A finished call and what to run on it.
    struct RecordedCall {
        let folder: URL
        let pipeline: PipelineConfig
        let steps: [String]
    }

    static func listen(_ options: Options) async throws -> RecordedCall? {
        var config = MemoirConfig.load()
        if let out = options.out { config.saveDir = out }
        if let server = options.server { config.server = server }
        if let tokenFile = options.tokenFile { config.tokenFile = tokenFile }
        if options.saveAudio { config.saveAudio = true }
        guard let server = URL(string: config.server) else { throw UsageError(message: "bad server URL \(config.server)") }

        // What to run after the call — recorded in meeting.json, so `memoir process` knows later.
        var pipeline: PipelineConfig?
        var choice: PostprocessChoice?
        do {
            pipeline = try PipelineConfig.load(path: options.pipeline)
        } catch {
            Terminal.err("memoir: \(error) — nothing will run after the call\n")
        }
        if let pipeline {
            if let unknown = options.steps?.first(where: { pipeline.step($0) == nil }) {
                throw UsageError(message: "--steps: there is no step \(unknown) in the pipeline")
            }
            let steps = !options.process ? [] : options.steps.map { pipeline.selection($0, keepLocal: options.keepLocal) }
                ?? pipeline.defaultSteps(keepLocal: options.keepLocal)
            choice = PostprocessChoice(steps: steps, keepLocal: options.keepLocal)
        }

        let sources = options.sources
        let name = options.name.isEmpty ? (options.input?.deletingPathExtension().lastPathComponent ?? "") : options.name
        let store = options.record
            ? try MeetingStore(saveDir: config.saveDirectory, name: name, prep: options.prep, sources: sources,
                               client: "memoir-cli", saveAudio: config.saveAudio, postprocess: choice)
            : nil
        let session = MeetingSession(options: SessionOptions(
            server: server, token: try config.token(), sources: sources, name: name, prep: options.prep,
            input: options.input, app: "memoir-cli", echoGate: config.echoGate && options.echoGate))
        if let store, store.saveAudio {
            session.onAudio = { source, samples in try? store.record(audio: samples, from: source) }
        }

        let events: AsyncStream<SessionEvent>
        do {
            events = try await session.start()
        } catch {
            store?.discardIfEmpty()  // don't leave an empty call folder behind
            throw error
        }
        if let store { Terminal.err("recording to \(store.folder.path)\n") }
        if store != nil, let pipeline, let steps = choice?.steps, !steps.isEmpty {
            Terminal.err("after the call: \(steps.compactMap { pipeline.step($0)?.label }.joined(separator: ", "))\n")
        }
        let presses = Once()
        _ = signal(SIGINT, SIG_IGN)  // handled by the dispatch source below
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler {
            if presses.next() > 1 { exit(130) }  // second Ctrl-C: give up waiting
            session.stop()
        }
        sigint.resume()
        defer { sigint.cancel() }

        var transcript = LiveTranscript(labelled: sources.count > 1)
        var failed: String?
        for await event in events {
            switch event {
            case .ready(let model, let chunkMs):
                Terminal.err("connected to \(server.host ?? "server"): \(model), \(chunkMs) ms chunks\n")
                try? store?.setServer(model: model, chunkMs: chunkMs)
            case .capturing(let what):
                for line in what { Terminal.err("listening to \(line)\n") }
                Terminal.err("Ctrl-C to stop\n")
            case .message(let msg):
                switch msg.type {
                case "final":
                    try store?.record(final: msg)
                    Terminal.render(transcript.handle(msg))
                case "partial":
                    Terminal.render(transcript.handle(msg))
                case "error":
                    Terminal.err("\nserver: \(msg.code ?? "?"): \(msg.message ?? "")\n")
                default:
                    break
                }
            case .silenceHint:
                Terminal.err("\r\u{1B}[2Kno system audio yet — if something is playing, allow your terminal app under "
                             + "System Settings › Privacy & Security › Screen & System Audio Recording "
                             + "(System Audio Recording Only), then restart it\n")
            case .stopped(let serverPath, let latency):
                Terminal.render(transcript.finish())
                try store?.finish(serverPath: serverPath)
                Terminal.err("\n")
                if let store { Terminal.err("saved to \(store.folder.path)\n") }
                Terminal.err("server backup: \(serverPath ?? "?")\n\(latency.summary)\n")
                if let gate = session.echoGate?.stats {
                    try? store?.setEchoGate(gate)
                    Terminal.err(String(format: "echo gate: silenced %.1f s of %.0f s of mic audio", gate.gatedSeconds, gate.micSeconds)
                                 + (gate.leakDb.map { String(format: " (the call leaked into the mic at %.0f dB)", $0) } ?? "") + "\n")
                }
            case .failed(let message):
                failed = message
            }
        }
        if let failed {
            Terminal.render(transcript.finish())
            try? store?.finish(serverPath: nil)
            if let store { Terminal.err("\nsaved what was transcribed to \(store.folder.path)\n") }
            throw CLIFailure(message: failed)
        }
        guard let store, let pipeline, let steps = choice?.steps, !steps.isEmpty else { return nil }
        return RecordedCall(folder: store.folder, pipeline: pipeline, steps: steps)
    }

    /// Runs the chosen steps once the call is saved — unless it's too short to be worth it.
    static func processAfterCall(_ call: RecordedCall) async -> Int32 {
        let finals = (try? CallInfo.load(call.folder))?.finals ?? 0
        guard finals >= call.pipeline.minFinals else {
            Terminal.err("too short to process (\(finals) lines; min_finals is \(call.pipeline.minFinals)) — "
                         + "to process it anyway: memoir process \(call.folder.path)\n")
            return 0
        }
        Terminal.err("\n")
        do {
            return try await runPipeline(call.pipeline, on: call.folder, steps: call.steps, force: false, verbose: false)
        } catch {
            Terminal.err("memoir: \(error)\n")
            return 1
        }
    }

    static func process(_ options: ProcessOptions) async throws -> Int32 {
        guard let pipeline = try PipelineConfig.load(path: options.pipeline) else {
            throw CLIFailure(message: "no pipeline at \(options.pipeline) — see INSTALL.md (After the call)")
        }
        let info: CallInfo
        do {
            info = try CallInfo.load(options.folder)
        } catch {
            throw CLIFailure(message: "\(options.folder.path) is not a call folder (no readable meeting.json)")
        }
        if options.list {
            list(pipeline, info)
            return 0
        }
        if let unknown = options.steps.first(where: { pipeline.step($0) == nil }) {
            throw UsageError(message: "--step: there is no step \(unknown); the pipeline has "
                             + pipeline.steps.map(\.id).joined(separator: ", "))
        }
        let keepLocal = info.postprocess?.keepLocal ?? false
        var steps = options.steps
        if steps.isEmpty {
            let chosen = info.postprocess?.steps ?? []
            steps = chosen.isEmpty ? pipeline.defaultSteps(keepLocal: keepLocal && !options.allowRemote) : chosen
        }
        let remote = pipeline.selection(steps).compactMap(pipeline.step).filter(\.remote)
        if keepLocal, !options.allowRemote, !remote.isEmpty {
            throw CLIFailure(message: "this call is marked keep-local, and \(remote.map(\.label).joined(separator: ", ")) "
                             + "would send it off this Mac — add --allow-remote to run anyway")
        }
        if steps.isEmpty {
            Terminal.err("nothing to run: no steps are chosen for this call or marked default\n")
            return 0
        }
        if info.endedAt == nil {
            Terminal.err("note: the call has no end time — it's still recording, or it was cut off\n")
        }
        return try await runPipeline(pipeline, on: options.folder, steps: steps,
                                     force: options.force || !options.steps.isEmpty, verbose: options.verbose)
    }

    /// Runs the steps, printing progress on stderr and the links they produce on stdout. Ctrl-C cancels.
    static func runPipeline(_ pipeline: PipelineConfig, on folder: URL, steps: [String], force: Bool,
                            verbose: Bool) async throws -> Int32 {
        let runner = PipelineRunner(config: pipeline, call: folder)
        if verbose { runner.onOutput = { _, data in FileHandle.standardError.write(data) } }
        let presses = Once()
        _ = signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler {
            if presses.next() > 1 { exit(130) }
            Terminal.err("\ncancelling…\n")
            runner.cancel()
        }
        sigint.resume()
        defer { sigint.cancel() }

        Terminal.err("processing \(folder.lastPathComponent)\n")
        let progress = StepProgress(pipeline: pipeline, folder: folder)
        let state = try await runner.run(steps: steps, force: force) { progress.show($0) }
        progress.finish(state, requested: pipeline.selection(steps))

        let ran = progress.ran
        for id in pipeline.selection(steps) {
            if let url = state.steps[id]?.url { print(url) }
        }
        if ran.contains(where: { state.steps[$0]?.status == .cancelled }) { return 130 }
        return ran.allSatisfy({ state.steps[$0]?.status == .ok }) ? 0 : 1
    }

    static func list(_ pipeline: PipelineConfig, _ info: CallInfo) {
        let state = PipelineState.load(info.folder)
        let chosen = info.postprocess.map { $0.steps.isEmpty ? "none" : $0.steps.joined(separator: ", ") } ?? "not recorded"
        print("\(info.folder.lastPathComponent) — \(info.title): \(info.finals) lines; chosen: \(chosen)"
              + (info.postprocess?.keepLocal == true ? "; keep local" : ""))
        let width = pipeline.steps.map(\.id.count).max() ?? 0
        for step in pipeline.steps {
            let s = state?.steps[step.id]
            var line = "  \(step.id.padding(toLength: width, withPad: " ", startingAt: 0))  "
                + "\((s?.status.rawValue ?? "not run").padding(toLength: 9, withPad: " ", startingAt: 0))"
            if let finished = s?.finishedAt { line += "  \(finished.formatted(date: .abbreviated, time: .shortened))" }
            if let url = s?.url { line += "  \(url)" } else if let outputs = s?.outputs, !outputs.isEmpty {
                line += "  \(outputs.joined(separator: ", "))"
            }
            if let message = s?.message { line += "  — \(message)" }
            print(line + (step.remote ? "" : "  (local)"))
        }
    }
}

/// Prints each step's progress once per change.
final class StepProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let pipeline: PipelineConfig
    private let folder: URL
    private var shown: [String: StepState.Status] = [:]
    private(set) var ran: [String] = []

    init(pipeline: PipelineConfig, folder: URL) {
        self.pipeline = pipeline
        self.folder = folder
    }

    func show(_ state: PipelineState) {
        lock.withLock {
            for step in pipeline.steps {
                guard let s = state.steps[step.id], shown[step.id] != s.status else { continue }
                if s.status == .pending { ran.append(step.id) }
                guard ran.contains(step.id) else { continue }  // earlier results: shown at the end
                shown[step.id] = s.status
                let took = s.startedAt.map { " (\(durationText((s.finishedAt ?? Date()).timeIntervalSince($0))))" } ?? ""
                let log = PipelineState.log(folder, step: step.id).path
                switch s.status {
                case .pending: break
                case .running: Terminal.err("▶ \(step.label)…\n")
                case .ok: Terminal.err("✓ \(step.label)\(took)\(s.url.map { " — \($0)" } ?? "")\n")
                case .failed: Terminal.err("✗ \(step.label)\(took): \(s.message ?? "failed")\n  log: \(log)\n")
                case .skipped: Terminal.err("– \(step.label): \(s.message ?? "skipped")\n")
                case .cancelled: Terminal.err("■ \(step.label): cancelled\n")
                }
            }
        }
    }

    /// Mentions requested steps that didn't need to run.
    func finish(_ state: PipelineState, requested: [String]) {
        lock.withLock {
            for id in requested where !ran.contains(id) {
                guard let step = pipeline.step(id), state.steps[id]?.status == .ok else { continue }
                Terminal.err("✓ \(step.label) (done earlier\(state.steps[id]?.url.map { ": \($0)" } ?? ""); --force to redo)\n")
            }
        }
    }
}

struct CLIFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
