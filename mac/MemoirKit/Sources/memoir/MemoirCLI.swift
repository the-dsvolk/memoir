import Foundation
import MemoirKit

let usage = """
    usage: memoir listen [options]

    Streams your microphone (or an audio file) to memoir-asr on the Spark and prints the live transcript.
    Partial text updates in place on stderr; finished sentences are printed to stdout.

    options:
      --server URL       server endpoint (default ws://spark-0e81.local:8770/v1/stream)
      --token-file PATH  bearer token file (default ~/.config/memoir/token; or set MEMOIR_TOKEN)
      --input FILE       stream an audio file in real time instead of the microphone
      --save FILE.wav    also save the captured audio (16 kHz mono)
      --title TEXT       meeting title stored with the transcript
      -h, --help         show this help

    Stop with Ctrl-C.
    """

struct Options {
    var server = URL(string: "ws://spark-0e81.local:8770/v1/stream")!
    var tokenFile = "~/.config/memoir/token"
    var input: URL?
    var save: URL?
    var title = ""

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
        let client = StreamClient(url: options.server, token: try options.token())
        let title = options.title.isEmpty ? (options.input?.lastPathComponent ?? "microphone") : options.title
        let meetingId = "cli-" + UUID().uuidString.prefix(6).lowercased()
        let ready = try await client.open(StartMessage(meetingId: meetingId, title: title, app: "memoir-cli", sources: [.me]))
        let chunkSamples = UInt64((ready.chunkMs ?? 560) * Wire.sampleRate / 1000)
        Terminal.err("connected to \(options.server.host ?? "server"): \(ready.model ?? "?"), \(ready.chunkMs ?? 0) ms chunks\n")

        let sendLog = SendLog()
        let receiver = Task { () throws -> (String?, Latency) in
            var transcript = LiveTranscript()
            var latency = Latency()
            while true {
                let msg = try await client.receive()
                switch msg.type {
                case "partial", "final":
                    if msg.type == "partial", let text = msg.text, !text.isEmpty, let upto = msg.upto {
                        let now = ProcessInfo.processInfo.systemUptime
                        let end = UInt64((upto * Double(Wire.sampleRate)).rounded())
                        if let sentEnd = sendLog.time(reaching: end),
                           let sentStart = sendLog.time(reaching: end > chunkSamples ? end - chunkSamples : 0) {
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

        let writer = try options.save.map { try WAVWriter(url: $0) }
        var framer = Framer()
        func send(_ frames: [Framer.Frame]) async throws {
            for frame in frames {
                try await client.sendAudio(source: .me, frame: frame)
                sendLog.record(end: frame.offset + UInt64(frame.samples.count))
            }
        }

        if let input = options.input {
            let samples = try AudioFile.load(input)
            try writer?.append(samples)
            Terminal.err("streaming \(input.lastPathComponent) (\(String(format: "%.1f", Double(samples.count) / Double(Wire.sampleRate))) s) in real time\n")
            let clock = ContinuousClock()
            let start = clock.now
            for frame in framer.push(samples + [Int16](repeating: 0, count: 2 * Wire.sampleRate)) {  // + 2 s silence
                let endMs = (Int(frame.offset) + frame.samples.count) * 1000 / Wire.sampleRate
                try await clock.sleep(until: start + .milliseconds(endMs))  // pace like a live mic
                try await send([frame])
            }
            if let last = framer.flush() { try await send([last]) }
        } else {
            guard await MicCapture.requestAccess() else { throw MemoirError.microphoneDenied }
            let mic = MicCapture()
            let chunks = try mic.start()
            let presses = Once()
            _ = signal(SIGINT, SIG_IGN)  // handled by the dispatch source below
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            sigint.setEventHandler {
                if presses.next() > 1 { exit(130) }  // second Ctrl-C: give up waiting
                mic.stop()
            }
            sigint.resume()
            Terminal.err("listening on \(MicCapture.defaultInputName) — Ctrl-C to stop\n")
            for await chunk in chunks {
                try writer?.append(chunk)
                try await send(framer.push(chunk))
            }
            sigint.cancel()
            if let last = framer.flush() { try await send([last]) }
        }

        try await client.sendStop()
        let (path, latency) = try await receiver.value
        try writer?.close()
        client.close()
        Terminal.err("\nsaved on the server: \(path ?? "?")\n\(latency.report())\n")
        if let save = options.save { Terminal.err("audio saved to \(save.path)\n") }
    }
}
