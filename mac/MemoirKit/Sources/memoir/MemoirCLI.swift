import Foundation
import MemoirKit

let usage = """
    usage: memoir listen [options]

    Streams your microphone and/or what the Mac is playing to memoir-asr on the Spark, prints the live
    transcript, and records the call in its own folder: <save dir>/YYYY-MM-DD_<name>/ (DESIGN.md §4.7).
    Partial text updates in place on stderr; finished sentences are printed to stdout.

    options:
      --source SRC       mic (default), system (what the Mac plays: YouTube, calls, …), or mic+system
      --name TEXT        the call's name (folder name and title); default untitled-call-HHMM
      --notes TEXT       context notes for the call (attendees, agenda, …) → notes.md
      --out DIR          save folder (default from ~/.config/memoir/config.toml, else ~/memoir)
      --save-audio       also save the audio, one WAV per source, in the call's folder
      --no-record        don't write a call folder (quick tests)
      --input FILE       stream an audio file in real time instead of capturing
      --server URL       server endpoint (default from the config, else ws://spark-0e81.local:8770/v1/stream)
      --token-file PATH  bearer token file (default ~/.config/memoir/token; or set MEMOIR_TOKEN)
      -h, --help         show this help

    Settings shared with Memoir.app live in ~/.config/memoir/config.toml.
    Stop with Ctrl-C. With mic+system use headphones, or the mic hears the Mac's audio too.
    """

struct Options {
    var source = "mic"
    var name = ""
    var notes = ""
    var out: String?
    var saveAudio = false
    var record = true
    var input: URL?
    var server: String?
    var tokenFile: String?

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
        guard let command = args.first, command == "listen" else { throw UsageError() }
        var rest = args.dropFirst()
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
            return v
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--source":
                options.source = try value(flag)
                guard ["mic", "system", "mic+system"].contains(options.source) else {
                    throw UsageError(message: "--source must be mic, system or mic+system")
                }
            case "--name", "--title": options.name = try value(flag)
            case "--notes": options.notes = try value(flag)
            case "--out": options.out = try value(flag)
            case "--save-audio": options.saveAudio = true
            case "--no-record": options.record = false
            case "--input": options.input = URL(fileURLWithPath: try value(flag))
            case "--server": options.server = try value(flag)
            case "--token-file": options.tokenFile = try value(flag)
            case "-h", "--help": throw UsageError()
            default: throw UsageError(message: "unknown option \(flag)")
            }
        }
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
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try await listen(options)
        } catch let error as UsageError {
            if let message = error.message { Terminal.err("memoir: \(message)\n\n") }
            Terminal.err(usage + "\n")
            exit(2)
        } catch {
            Terminal.err("\nmemoir: \(error)\n")
            exit(1)
        }
    }

    static func listen(_ options: Options) async throws {
        var config = MemoirConfig.load()
        if let out = options.out { config.saveDir = out }
        if let server = options.server { config.server = server }
        if let tokenFile = options.tokenFile { config.tokenFile = tokenFile }
        if options.saveAudio { config.saveAudio = true }
        guard let server = URL(string: config.server) else { throw UsageError(message: "bad server URL \(config.server)") }

        let sources = options.sources
        let name = options.name.isEmpty ? (options.input?.deletingPathExtension().lastPathComponent ?? "") : options.name
        let store = options.record
            ? try MeetingStore(saveDir: config.saveDirectory, name: name, context: options.notes, sources: sources,
                               client: "memoir-cli", saveAudio: config.saveAudio)
            : nil
        let session = MeetingSession(options: SessionOptions(
            server: server, token: try config.token(), sources: sources, name: name, context: options.notes,
            input: options.input, app: "memoir-cli"))
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
    }
}

struct CLIFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
