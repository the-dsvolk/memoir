import Foundation
import MemoirKit

let usage = """
    usage: memoir listen [options]

    Streams your microphone and/or what the Mac is playing to memoir-asr on the Spark and prints the
    live transcript. Partial text updates in place on stderr; finished sentences are printed to stdout.

    options:
      --source SRC       mic (default), system (what the Mac plays: YouTube, calls, …), or mic+system
      --server URL       server endpoint (default ws://spark-0e81.local:8770/v1/stream)
      --token-file PATH  bearer token file (default ~/.config/memoir/token; or set MEMOIR_TOKEN)
      --input FILE       stream an audio file in real time instead of capturing
      --save FILE.wav    also save the captured audio, 16 kHz mono (mic+system: FILE-me.wav, FILE-them.wav)
      --title TEXT       meeting title stored with the transcript
      -h, --help         show this help

    Stop with Ctrl-C. With mic+system use headphones, or the mic hears the Mac's audio too.
    """

struct Options {
    var server = URL(string: "ws://spark-0e81.local:8770/v1/stream")!
    var tokenFile = "~/.config/memoir/token"
    var source = "mic"
    var input: URL?
    var save: URL?
    var title = ""

    /// Audio sources to capture and their wire labels: mic → me, system → them.
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
            case "--server":
                guard let url = URL(string: try value(flag)) else { throw UsageError(message: "bad --server URL") }
                options.server = url
            case "--token-file": options.tokenFile = try value(flag)
            case "--input": options.input = URL(fileURLWithPath: try value(flag))
            case "--save": options.save = URL(fileURLWithPath: try value(flag))
            case "--title": options.title = try value(flag)
            case "-h", "--help": throw UsageError()
            default: throw UsageError(message: "unknown option \(flag)")
            }
        }
        return options
    }

    func token() throws -> String {
        if let env = ProcessInfo.processInfo.environment["MEMOIR_TOKEN"], !env.isEmpty { return env }
        let path = (tokenFile as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageError(message: "no token: copy ~/.config/memoir/token from spark-0e81 (see INSTALL.md)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where to save one source's audio: FILE.wav, or FILE-<source>.wav when there are several.
    func saveURL(for source: Source) -> URL? {
        guard let save else { return nil }
        guard sources.count > 1 else { return save }
        let base = save.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)-\(source.name).wav")
    }
}

struct UsageError: Error {
    var message: String?
}

/// When each frame ending at a given sample offset was sent — for latency.
final class SendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ends: [UInt64] = []
    private var times: [Double] = []

    func record(end: UInt64) {
        lock.withLock {
            ends.append(end)
            times.append(ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Send time of the first frame that reaches `offset`.
    func time(reaching offset: UInt64) -> Double? {
        lock.withLock {
            var lo = 0, hi = ends.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ends[mid] < offset { lo = mid + 1 } else { hi = mid }
            }
            return lo < times.count ? times[lo] : nil
        }
    }
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

struct Latency: Sendable {
    var afterChunkEnd: [Double] = []
    var afterChunkStart: [Double] = []

    func report() -> String {
        func p(_ values: [Double], _ q: Double) -> Double {
            let s = values.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
        }
        guard !afterChunkEnd.isEmpty else { return "latency: no partials" }
        return String(format: "partial latency: %.2f s p50 / %.2f s p95 after a chunk ends, %.2f s p50 after it starts (%d partials)",
                      p(afterChunkEnd, 0.5), p(afterChunkEnd, 0.95), p(afterChunkStart, 0.5), afterChunkEnd.count)
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// One capture running: its stream of 16 kHz chunks and how to stop it.
struct Capture: Sendable {
    let source: Source
    let chunks: AsyncStream<[Int16]>
    let description: String
    let stop: @Sendable () -> Void
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
        let sources = options.sources
        let client = StreamClient(url: options.server, token: try options.token())
        let title = options.title.isEmpty ? (options.input?.lastPathComponent ?? options.source) : options.title
        let meetingId = "cli-" + UUID().uuidString.prefix(6).lowercased()
        let ready = try await client.open(StartMessage(meetingId: meetingId, title: title, app: "memoir-cli", sources: sources))
        let chunkSamples = UInt64((ready.chunkMs ?? 560) * Wire.sampleRate / 1000)
        Terminal.err("connected to \(options.server.host ?? "server"): \(ready.model ?? "?"), \(ready.chunkMs ?? 0) ms chunks\n")

        let sendLogs = Dictionary(uniqueKeysWithValues: sources.map { ($0.name, SendLog()) })
        let receiver = Task { () throws -> (String?, Latency) in
            var transcript = LiveTranscript(labelled: sources.count > 1)
            var latency = Latency()
            while true {
                let msg = try await client.receive()
                switch msg.type {
                case "partial", "final":
                    if msg.type == "partial", let text = msg.text, !text.isEmpty, let upto = msg.upto,
                       let log = sendLogs[msg.source ?? "me"] {
                        let now = ProcessInfo.processInfo.systemUptime
                        let end = UInt64((upto * Double(Wire.sampleRate)).rounded())
                        if let sentEnd = log.time(reaching: end),
                           let sentStart = log.time(reaching: end > chunkSamples ? end - chunkSamples : 0) {
                            latency.afterChunkEnd.append(now - sentEnd)
                            latency.afterChunkStart.append(now - sentStart)
                        }
                    }
                    Terminal.render(transcript.handle(msg))
                case "stopped":
                    Terminal.render(transcript.finish())
                    return (msg.path, latency)
                case "error":
                    Terminal.err("\nserver: \(msg.code ?? "?"): \(msg.message ?? "")\n")
                default:
                    break
                }
            }
        }

        var writers: [UInt8: WAVWriter] = [:]
        for source in sources {
            if let url = options.saveURL(for: source) { writers[source.rawValue] = try WAVWriter(url: url) }
        }
        var framers = Dictionary(uniqueKeysWithValues: sources.map { ($0.rawValue, Framer()) })
        func send(_ source: Source, _ frames: [Framer.Frame]) async throws {
            for frame in frames {
                try await client.sendAudio(source: source, frame: frame)
                sendLogs[source.name]?.record(end: frame.offset + UInt64(frame.samples.count))
            }
        }

        if let input = options.input {
            let samples = try AudioFile.load(input)
            try writers[Source.me.rawValue]?.append(samples)
            Terminal.err("streaming \(input.lastPathComponent) (\(String(format: "%.1f", Double(samples.count) / Double(Wire.sampleRate))) s) in real time\n")
            let clock = ContinuousClock()
            let start = clock.now
            var framer = Framer()
            for frame in framer.push(samples + [Int16](repeating: 0, count: 2 * Wire.sampleRate)) {  // + 2 s silence
                let endMs = (Int(frame.offset) + frame.samples.count) * 1000 / Wire.sampleRate
                try await clock.sleep(until: start + .milliseconds(endMs))  // pace like a live mic
                try await send(.me, [frame])
            }
            if let last = framer.flush() { try await send(.me, [last]) }
        } else {
            let captures = try await startCaptures(sources)
            for capture in captures { Terminal.err("listening to \(capture.description)\n") }
            Terminal.err("Ctrl-C to stop\n")

            // One sender loop for all sources: one socket, frames in arrival order.
            let (merged, mergedInput) = AsyncStream.makeStream(of: (Source, [Int16]).self, bufferingPolicy: .unbounded)
            let feeders = captures.map { capture in
                Task {
                    for await chunk in capture.chunks { mergedInput.yield((capture.source, chunk)) }
                }
            }
            Task {
                for feeder in feeders { await feeder.value }
                mergedInput.finish()
            }

            let presses = Once()
            _ = signal(SIGINT, SIG_IGN)  // handled by the dispatch source below
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            sigint.setEventHandler {
                if presses.next() > 1 { exit(130) }  // second Ctrl-C: give up waiting
                for capture in captures { capture.stop() }
            }
            sigint.resume()

            let startedAt = ProcessInfo.processInfo.systemUptime
            var heardSystemAudio = false
            var warnedSilence = false
            for await (source, chunk) in merged {
                if source == .them, !heardSystemAudio {
                    heardSystemAudio = chunk.contains { $0 != 0 }
                    if !heardSystemAudio, !warnedSilence, ProcessInfo.processInfo.systemUptime - startedAt > 5 {
                        warnedSilence = true
                        Terminal.err("\r\u{1B}[2Kno system audio yet — if something is playing, allow your terminal app under "
                                     + "System Settings › Privacy & Security › Screen & System Audio Recording "
                                     + "(System Audio Recording Only), then restart it\n")
                    }
                }
                try writers[source.rawValue]?.append(chunk)
                try await send(source, framers[source.rawValue]!.push(chunk))
            }
            sigint.cancel()
            for source in sources {
                if let last = framers[source.rawValue]!.flush() { try await send(source, [last]) }
            }
        }

        try await client.sendStop()
        let (path, latency) = try await receiver.value
        for writer in writers.values { try writer.close() }
        client.close()
        Terminal.err("\nsaved on the server: \(path ?? "?")\n\(latency.report())\n")
        for source in sources {
            if let url = options.saveURL(for: source) { Terminal.err("audio (\(source.name)) saved to \(url.path)\n") }
        }
    }

    static func startCaptures(_ sources: [Source]) async throws -> [Capture] {
        var captures: [Capture] = []
        if sources.contains(.me) {  // start the mic first: AirPods can otherwise stay in A2DP (DESIGN.md §4.2)
            guard await MicCapture.requestAccess() else { throw MemoirError.microphoneDenied }
            let mic = MicCapture()
            captures.append(Capture(source: .me, chunks: try mic.start(),
                                    description: "the microphone (\(MicCapture.defaultInputName)) as Me",
                                    stop: { mic.stop() }))
        }
        if sources.contains(.them) {
            let system = SystemAudioCapture()
            let chunks = try system.start()
            captures.append(Capture(source: .them, chunks: chunks,
                                    description: "system audio (\(system.outputDeviceName), \(system.tapFormat)) as Them",
                                    stop: { system.stop() }))
        }
        return captures
    }
}
