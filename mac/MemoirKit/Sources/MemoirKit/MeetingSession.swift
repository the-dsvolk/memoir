import Foundation

/// What a session needs to run.
public struct SessionOptions: Sendable {
    public var server: URL
    public var token: String
    public var sources: [Source]
    public var name: String
    public var prep: String  // prep written before the call
    public var input: URL?  // stream this file (as "me") in real time instead of capturing
    public var app: String  // client label stored by the server ("memoir-app", "memoir-cli")

    public init(server: URL, token: String, sources: [Source], name: String, prep: String = "",
                input: URL? = nil, app: String) {
        self.server = server
        self.token = token
        self.sources = sources
        self.name = name
        self.prep = prep
        self.input = input
        self.app = app
    }
}

public enum SessionEvent: Sendable {
    case ready(model: String, chunkMs: Int)
    case capturing([String])  // what is being captured, for display
    case message(ServerMessage)  // partial, final, notes_ready, error
    case silenceHint  // system audio has been silent for 5 s — likely no permission
    case stopped(serverPath: String?, latency: LatencyStats)
    case failed(String)
}

/// One call: connects to memoir-asr, captures the sources, streams them and reports what comes back.
/// Shared by the CLI and the app (D13). Start once; `stop()` can be called from anywhere, any number
/// of times; the event stream ends after `.stopped` or `.failed`.
public final class MeetingSession: @unchecked Sendable {
    public let options: SessionOptions
    /// Called with every captured chunk (16 kHz mono) — e.g. to save audio. Set before `start()`.
    public var onAudio: (@Sendable (Source, [Int16]) -> Void)?

    private let client: StreamClient
    private let lock = NSLock()
    private var captures: [Capture] = []
    private var fileTask: Task<Void, Never>?
    private var startedAt: Double?
    private var stopping = false

    public init(options: SessionOptions) {
        self.options = options
        client = StreamClient(url: options.server, token: options.token)
    }

    /// Seconds since the server said `ready` — the meeting clock used for note timestamps.
    public var elapsed: Double {
        lock.withLock { startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0 }
    }

    public func start() async throws -> AsyncStream<SessionEvent> {
        let (events, emit) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        let meetingId = String(options.app.prefix(3)) + "-" + UUID().uuidString.prefix(6).lowercased()
        let ready = try await client.open(StartMessage(meetingId: meetingId, title: options.name,
                                                       prep: options.prep, app: options.app,
                                                       sources: options.sources))
        lock.withLock { startedAt = ProcessInfo.processInfo.systemUptime }
        let chunkMs = ready.chunkMs ?? 560
        emit.yield(.ready(model: ready.model ?? "?", chunkMs: chunkMs))

        let logs = Dictionary(uniqueKeysWithValues: options.sources.map { ($0.name, SendLog()) })
        let chunkSamples = UInt64(chunkMs * Wire.sampleRate / 1000)
        Task { [client] in
            var latency = LatencyStats()
            do {
                while true {
                    let msg = try await client.receive()
                    if msg.type == "stopped" {
                        emit.yield(.stopped(serverPath: msg.path, latency: latency))
                        break
                    }
                    if msg.type == "partial", let text = msg.text, !text.isEmpty, let upto = msg.upto,
                       let log = logs[msg.source ?? "me"] {
                        latency.record(upto: upto, log: log, chunkSamples: chunkSamples)
                    }
                    emit.yield(.message(msg))
                }
            } catch {
                emit.yield(.failed("lost the server: \(error.localizedDescription)"))
                self.stop()
            }
            client.close()
            emit.finish()
        }

        if let input = options.input {
            let task = Task { await self.streamFile(input, logs: logs, emit: emit) }
            lock.withLock { fileTask = task }
        } else {
            do {
                let captures = try await Capture.start(options.sources)
                lock.withLock { self.captures = captures }
                emit.yield(.capturing(captures.map(\.description)))
                Task { await self.pump(captures, logs: logs, emit: emit) }
            } catch {
                client.close()
                throw error
            }
        }
        return events
    }

    /// Stops capturing; the rest of the audio is flushed, then the server finishes and sends `stopped`.
    public func stop() {
        let (captures, fileTask) = lock.withLock { () -> ([Capture], Task<Void, Never>?) in
            if stopping { return ([], nil) }
            stopping = true
            return (self.captures, self.fileTask)
        }
        for capture in captures { capture.stop() }
        fileTask?.cancel()
    }

    public func sendNote(id: String, at t: Double, text: String) async throws {
        try await client.send(NoteMessage(id: id, t: t, text: text))
    }

    public func sendRename(to title: String) async throws {
        try await client.send(MetaMessage(title: title))
    }

    public func sendPrep(at t: Double, text: String) async throws {
        try await client.send(PrepMessage(t: t, text: text))
    }

    // MARK: - Sending

    private func send(_ source: Source, _ frames: [Framer.Frame], _ logs: [String: SendLog]) async throws {
        for frame in frames {
            try await client.sendAudio(source: source, frame: frame)
            logs[source.name]?.record(end: frame.offset + UInt64(frame.samples.count))
        }
    }

    /// All sources through one loop: one socket, frames in arrival order.
    private func pump(_ captures: [Capture], logs: [String: SendLog],
                      emit: AsyncStream<SessionEvent>.Continuation) async {
        let (merged, input) = AsyncStream.makeStream(of: (Source, [Int16]).self, bufferingPolicy: .unbounded)
        let feeders = captures.map { capture in
            Task { for await chunk in capture.chunks { input.yield((capture.source, chunk)) } }
        }
        Task {
            for feeder in feeders { await feeder.value }
            input.finish()
        }
        var framers = Dictionary(uniqueKeysWithValues: options.sources.map { ($0.rawValue, Framer()) })
        let began = ProcessInfo.processInfo.systemUptime
        var heardSystem = false, warned = false
        do {
            for await (source, chunk) in merged {
                if source == .them, !heardSystem {
                    heardSystem = chunk.contains { $0 != 0 }
                    if !heardSystem, !warned, ProcessInfo.processInfo.systemUptime - began > 5 {
                        warned = true
                        emit.yield(.silenceHint)
                    }
                }
                onAudio?(source, chunk)
                try await send(source, framers[source.rawValue]!.push(chunk), logs)
            }
            for source in options.sources {
                if let last = framers[source.rawValue]!.flush() { try await send(source, [last], logs) }
            }
            try await client.sendStop()
        } catch {
            emit.yield(.failed("couldn't send audio: \(error.localizedDescription)"))
            client.close()
        }
    }

    private func streamFile(_ url: URL, logs: [String: SendLog], emit: AsyncStream<SessionEvent>.Continuation) async {
        do {
            let samples = try AudioFile.load(url)
            emit.yield(.capturing([String(format: "%@ (%.1f s) in real time", url.lastPathComponent,
                                          Double(samples.count) / Double(Wire.sampleRate))]))
            onAudio?(.me, samples)
            var framer = Framer()
            let clock = ContinuousClock()
            let start = clock.now
            for frame in framer.push(samples + [Int16](repeating: 0, count: 2 * Wire.sampleRate)) {  // + 2 s silence
                if Task.isCancelled { break }
                let endMs = (Int(frame.offset) + frame.samples.count) * 1000 / Wire.sampleRate
                try? await clock.sleep(until: start + .milliseconds(endMs))  // pace like a live mic
                try await send(.me, [frame], logs)
            }
            if let last = framer.flush() { try await send(.me, [last], logs) }
            try await client.sendStop()
        } catch {
            emit.yield(.failed("couldn't stream \(url.lastPathComponent): \(error)"))
            client.close()
        }
    }
}

/// Partial latency, two ways: after the model chunk a partial covers ends (the server's own delay) and
/// after it starts (the worst case for a word).
public struct LatencyStats: Sendable {
    public private(set) var afterChunkEnd: [Double] = []
    public private(set) var afterChunkStart: [Double] = []

    mutating func record(upto: Double, log: SendLog, chunkSamples: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        let end = UInt64((upto * Double(Wire.sampleRate)).rounded())
        guard let sentEnd = log.time(reaching: end),
              let sentStart = log.time(reaching: end > chunkSamples ? end - chunkSamples : 0) else { return }
        afterChunkEnd.append(now - sentEnd)
        afterChunkStart.append(now - sentStart)
    }

    public var summary: String {
        func p(_ values: [Double], _ q: Double) -> Double {
            let s = values.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
        }
        guard !afterChunkEnd.isEmpty else { return "latency: no partials" }
        return String(format: "partial latency: %.2f s p50 / %.2f s p95 after a chunk ends, %.2f s p50 after it starts (%d partials)",
                      p(afterChunkEnd, 0.5), p(afterChunkEnd, 0.95), p(afterChunkStart, 0.5), afterChunkEnd.count)
    }
}

/// When each frame ending at a given sample offset was sent.
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

/// One running capture: its stream of 16 kHz chunks and how to stop it.
struct Capture: Sendable {
    let source: Source
    let chunks: AsyncStream<[Int16]>
    let description: String
    let stop: @Sendable () -> Void

    static func start(_ sources: [Source]) async throws -> [Capture] {
        var captures: [Capture] = []
        if sources.contains(.me) || sources.contains(.room) {  // mic first: AirPods can stay in A2DP otherwise
            guard await MicCapture.requestAccess() else { throw MemoirError.microphoneDenied }
            let mic = MicCapture()
            let source: Source = sources.contains(.room) ? .room : .me
            captures.append(Capture(source: source, chunks: try mic.start(),
                                    description: "the microphone (\(MicCapture.defaultInputName)) as \(source.label)",
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
