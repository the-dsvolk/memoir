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
    /// With mic + system audio: silence the mic while it only hears the call (`EchoGate`).
    public var echoGate: Bool

    public init(server: URL, token: String, sources: [Source], name: String, prep: String = "",
                input: URL? = nil, app: String, echoGate: Bool = true) {
        self.server = server
        self.token = token
        self.sources = sources
        self.name = name
        self.prep = prep
        self.input = input
        self.app = app
        self.echoGate = echoGate
    }
}

public enum SessionEvent: Sendable {
    case ready(model: String, chunkMs: Int, serverVersion: String?)  // version: servers since 0.3
    case capturing([String])  // what is being captured, for display
    case message(ServerMessage)  // partial, final, notes_ready, error — in the call's times and numbering
    case silenceHint  // system audio has been silent for 5 s — likely no permission
    /// The connection dropped: capture goes on, the audio is kept, the session reconnects (DESIGN.md §6).
    case reconnecting(reason: String)
    /// Connected again after `downtime` seconds; the audio since the last finished line is re-sent.
    case reconnected(downtime: Double)
    case stopped(serverPath: String?, latency: LatencyStats)
    case failed(String)
}

/// One call: connects to memoir-asr, captures the sources, streams them and reports what comes back —
/// reconnecting if the connection drops. Shared by the CLI and the app (D13). Start once; `stop()` can
/// be called from anywhere, any number of times; the event stream ends after `.stopped` or `.failed`.
public final class MeetingSession: @unchecked Sendable {
    public let options: SessionOptions
    /// Called with every captured chunk (16 kHz mono) — e.g. to save audio. Set before `start()`.
    public var onAudio: (@Sendable (Source, [Int16]) -> Void)?

    /// The echo gate in use (mic + system audio with `echoGate` on), for its stats at the end.
    public let echoGate: EchoGate?

    /// How long to keep trying to reconnect — and so how much audio to hold — before giving up.
    var maxOutage: Double = 300
    /// After Stop with no connection: how long to keep trying, to send the rest of the audio.
    var finishGrace: Double = 20
    /// Waits between reconnect attempts; the last one repeats.
    var retryDelays: [Double] = [0.25, 0.5, 1, 2, 3, 5]
    var pingInterval: Double = 5
    /// Tests: captures to use instead of the microphone and system audio.
    var captureOverride: (@Sendable () -> [Capture])?

    private let meetingId: String
    private let lock = NSLock()
    private var client: StreamClient?  // the live connection, for notes and renames
    private var title: String
    private var captures: [Capture] = []
    private var startedAt: Double?
    private var stopping = false

    public init(options: SessionOptions) {
        self.options = options
        title = options.name
        meetingId = String(options.app.prefix(3)) + "-" + UUID().uuidString.prefix(6).lowercased()
        let both = options.sources.contains(.me) && options.sources.contains(.them)
        echoGate = options.echoGate && both && options.input == nil ? EchoGate() : nil
    }

    /// Seconds since the server said `ready` — the meeting clock used for note timestamps.
    public var elapsed: Double {
        lock.withLock { startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0 }
    }

    public func start() async throws -> AsyncStream<SessionEvent> {
        let (events, emit) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        let first = StreamClient(url: options.server, token: options.token)
        let ready = try await first.open(startMessage())
        lock.withLock {
            startedAt = ProcessInfo.processInfo.systemUptime
            client = first
        }
        let chunkMs = ready.chunkMs ?? 560
        emit.yield(.ready(model: ready.model ?? "?", chunkMs: chunkMs, serverVersion: ready.serverVersion))

        let captures: [Capture]
        do {
            if let captureOverride {
                captures = captureOverride()
            } else if let input = options.input {
                captures = [try Capture.file(input)]
            } else {
                captures = try await Capture.start(options.sources, echoGate: echoGate)
            }
        } catch {
            first.close()
            throw error
        }
        lock.withLock { self.captures = captures }
        emit.yield(.capturing(captures.map(\.description)))
        let pump = SessionPump(session: self, emit: emit, chunkMs: chunkMs)
        Task { await pump.run(first: first, captures: captures) }
        return events
    }

    /// Stops capturing; the rest of the audio is flushed, then the server finishes and sends `stopped`.
    public func stop() {
        let captures = lock.withLock { () -> [Capture] in
            if stopping { return [] }
            stopping = true
            return self.captures
        }
        for capture in captures { capture.stop() }
    }

    public func sendNote(id: String, at t: Double, text: String) async throws {
        try await live().send(NoteMessage(id: id, t: t, text: text))
    }

    public func sendRename(to title: String) async throws {
        lock.withLock { self.title = title }  // a reconnect then starts under the new name
        try await live().send(MetaMessage(title: title))
    }

    public func sendPrep(at t: Double, text: String) async throws {
        try await live().send(PrepMessage(t: t, text: text))
    }

    // MARK: - For the pump

    func startMessage() -> StartMessage {
        StartMessage(meetingId: meetingId, title: lock.withLock { title }, prep: options.prep, app: options.app,
                     sources: options.sources)
    }

    func setLive(_ client: StreamClient?) { lock.withLock { self.client = client } }

    private func live() throws -> StreamClient {
        guard let client = lock.withLock({ client }) else { throw MemoirError.disconnected }
        return client
    }
}

/// The session's loop: sends the captured audio over the live connection; when it drops, keeps the
/// audio, reconnects and re-sends from the end of the last finished line (DESIGN.md §6, Reconnecting).
/// Everything arrives as an `Event` and is handled in order on one task, so its state needs no lock.
final class SessionPump: @unchecked Sendable {
    enum Event: Sendable {
        case audio(Source, [Int16])
        case captureEnded
        case lost(Int, String)  // connection id, why
        case connected(Int, StreamClient, ServerMessage)
        case gaveUp(String)
        case serverStopped(Int, String?)
    }

    private struct Connection {
        let id: Int
        let client: StreamClient
        let link: Timeline.Link
        var framers: [UInt8: Framer]
        let tasks: [Task<Void, Never>]  // its reader and pinger
    }

    private let session: MeetingSession
    private let emit: AsyncStream<SessionEvent>.Continuation
    private let events: AsyncStream<Event>
    private let post: AsyncStream<Event>.Continuation
    private let shared = SessionShared()
    private let logs: [String: SendLog]
    private let chunkSamples: UInt64
    private let historyLimit: Int

    private var live: Connection?
    private var lastId = 0
    private var history: [String: AudioHistory] = [:]
    private var outageStart: Double?
    private var reconnector: Task<Void, Never>?
    private var capturesLeft = 0
    private var finishing = false
    private var done = false
    private let began = ProcessInfo.processInfo.systemUptime
    private var heardSystem = false
    private var warnedSilence = false

    init(session: MeetingSession, emit: AsyncStream<SessionEvent>.Continuation, chunkMs: Int) {
        self.session = session
        self.emit = emit
        (events, post) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        logs = Dictionary(uniqueKeysWithValues: session.options.sources.map { ($0.name, SendLog()) })
        chunkSamples = UInt64(chunkMs * Wire.sampleRate / 1000)
        historyLimit = Int(session.maxOutage + 30) * Wire.sampleRate
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func run(first: StreamClient, captures: [Capture]) async {
        capturesLeft = captures.count
        for capture in captures {
            Task { [post] in
                for await chunk in capture.chunks { post.yield(.audio(capture.source, chunk)) }
                post.yield(.captureEnded)
            }
        }
        live = attach(first, id: 0, link: Timeline.Link())
        for await event in events {
            switch event {
            case .audio(let source, let chunk): await audio(source, chunk)
            case .captureEnded:
                capturesLeft -= 1
                if capturesLeft == 0 { await beginFinishing() }
            case .lost(let id, let reason):
                if live?.id == id { lose(reason) }
            case .connected(let id, let client, _): await reconnected(id, client)
            case .gaveUp(let reason):
                finish(finishing ? .stopped(serverPath: nil, latency: shared.latencyStats)
                                 : .failed("lost the server and couldn't reconnect: \(reason)"))
            case .serverStopped(let id, let path):
                if live?.id == id { finish(.stopped(serverPath: path, latency: shared.latencyStats)) }
            }
            if done { break }
        }
    }

    // MARK: - Audio

    private func audio(_ source: Source, _ chunk: [Int16]) async {
        if source == .them, !heardSystem {
            heardSystem = chunk.contains { $0 != 0 }
            if !heardSystem, !warnedSilence, now - began > 5 {
                warnedSilence = true
                emit.yield(.silenceHint)
            }
        }
        session.onAudio?(source, chunk)
        history[source.name, default: AudioHistory()].append(chunk, keepFrom: shared.lastFinalEnd(source.name),
                                                             limit: historyLimit)
        guard var connection = live else { return }  // reconnecting: it's held, and re-sent after
        let frames = connection.framers[source.rawValue, default: Framer()].push(chunk)
        live = connection
        await send(frames, source, on: connection)
    }

    private func send(_ frames: [Framer.Frame], _ source: Source, on connection: Connection) async {
        for frame in frames {
            do {
                try await connection.client.sendAudio(source: source, frame: frame)
            } catch {
                if live?.id == connection.id { lose(describe(error)) }
                return
            }
            logs[source.name]?.record(end: connection.link.base(source.name) + frame.offset + UInt64(frame.samples.count))
        }
    }

    /// After Stop: send what's left and `stop`; without a connection, keep trying a little longer.
    private func beginFinishing() async {
        finishing = true
        guard let connection = live else {
            shared.deadline = min(shared.deadline, now + session.finishGrace)
            return
        }
        await flushAndStop(connection)
    }

    private func flushAndStop(_ connection: Connection) async {
        var connection = connection
        for source in session.options.sources {
            guard live?.id == connection.id else { return }
            if let last = connection.framers[source.rawValue]?.flush() {
                live = connection
                await send([last], source, on: connection)
            }
        }
        guard live?.id == connection.id else { return }
        do {
            try await connection.client.sendStop()
        } catch {
            if live?.id == connection.id { lose(describe(error)) }
        }
    }

    // MARK: - Connections

    private func attach(_ client: StreamClient, id: Int, link: Timeline.Link) -> Connection {
        shared.activate(id)
        session.setLive(client)
        let reader = Task { [post, shared, logs, chunkSamples, emit] in
            do {
                while true {
                    let msg = try await client.receive()
                    if msg.type == "stopped" {
                        post.yield(.serverStopped(id, msg.path))
                        return
                    }
                    shared.deliver(msg, from: id, link: link, logs: logs, chunkSamples: chunkSamples, to: emit)
                }
            } catch {
                post.yield(.lost(id, describe(error)))
            }
        }
        let interval = session.pingInterval
        let pinger = Task { [post] in  // notices a connection that died without an error
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                if await !client.ping(timeout: 2 * interval) {
                    post.yield(.lost(id, "the server stopped answering"))
                    return
                }
            }
        }
        return Connection(id: id, client: client, link: link, framers: [:], tasks: [reader, pinger])
    }

    private func lose(_ reason: String) {
        guard let connection = live else { return }
        live = nil
        for task in connection.tasks { task.cancel() }
        connection.client.close()
        session.setLive(nil)
        for cleared in shared.retire() { emit.yield(.message(cleared)) }
        outageStart = now
        shared.deadline = now + (finishing ? session.finishGrace : session.maxOutage)
        emit.yield(.reconnecting(reason: reason))
        lastId += 1
        reconnector = reconnect(id: lastId)
    }

    /// Tries to connect again until it works, the error can't be fixed by retrying, or the deadline passes.
    private func reconnect(id: Int) -> Task<Void, Never> {
        let session = session
        return Task { [post, shared] in
            var attempt = 0
            while !Task.isCancelled {
                let delays = session.retryDelays
                try? await Task.sleep(for: .seconds(delays[min(attempt, delays.count - 1)]))
                attempt += 1
                if Task.isCancelled { return }
                let client = StreamClient(url: session.options.server, token: session.options.token)
                do {
                    let ready = try await client.open(session.startMessage(), timeout: 10)
                    post.yield(.connected(id, client, ready))
                    return
                } catch {
                    client.close()
                    if !StreamClient.isRetryable(error) {
                        post.yield(.gaveUp(describe(error)))
                        return
                    }
                    if ProcessInfo.processInfo.systemUptime >= shared.deadline {
                        post.yield(.gaveUp("no connection since then — last error: \(describe(error))"))
                        return
                    }
                }
            }
        }
    }

    /// A new connection: re-send each source from the end of its last finished line, then carry on.
    private func reconnected(_ id: Int, _ client: StreamClient) async {
        guard live == nil, id == lastId, !done else {
            client.close()
            return
        }
        let held = history.mapValues(\.start)
        let link = shared.nextLink(held: held)
        let connection = attach(client, id: id, link: link)
        live = connection
        emit.yield(.reconnected(downtime: now - (outageStart ?? now)))
        for source in session.options.sources {
            guard var current = live, current.id == id else { return }  // dropped again while re-sending
            let backlog = history[source.name]?.samples(from: link.base(source.name)) ?? []
            let frames = current.framers[source.rawValue, default: Framer()].push(backlog)
            live = current
            await send(frames, source, on: current)
        }
        if finishing, let current = live, current.id == id { await flushAndStop(current) }
    }

    private func finish(_ event: SessionEvent) {
        done = true
        reconnector?.cancel()
        if let connection = live {
            for task in connection.tasks { task.cancel() }
            connection.client.close()
        }
        live = nil
        session.setLive(nil)
        session.stop()
        emit.yield(event)
        emit.finish()
        post.finish()
    }
}

/// An error as one line: URLSession's `localizedDescription` for network errors, ours otherwise.
private func describe(_ error: Error) -> String {
    if let memoir = error as? MemoirError { return memoir.description }
    return error.localizedDescription
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

/// When each frame ending at a given sample offset (in the call's numbering) was sent.
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

    /// With `echoGate`, the mic goes through it and the system audio feeds it.
    static func start(_ sources: [Source], echoGate: EchoGate? = nil) async throws -> [Capture] {
        var captures: [Capture] = []
        if sources.contains(.me) || sources.contains(.room) {  // mic first: AirPods can stay in A2DP otherwise
            guard await MicCapture.requestAccess() else { throw MemoirError.microphoneDenied }
            var process: (@Sendable ([Int16], Double) -> [Int16])?
            if let echoGate { process = { samples, time in echoGate.near(samples, at: time) } }
            let mic = MicCapture(process: process)
            let source: Source = sources.contains(.room) ? .room : .me
            let gated = echoGate == nil ? "" : ", echo gate on"
            captures.append(Capture(source: source, chunks: try mic.start(),
                                    description: "the microphone (\(MicCapture.defaultInputName)) as \(source.label)\(gated)",
                                    stop: { mic.stop() }))
        }
        if sources.contains(.them) {
            var observe: (@Sendable ([Int16], Double) -> Void)?
            if let echoGate { observe = { samples, time in echoGate.far(samples, at: time) } }
            let system = SystemAudioCapture(observe: observe)
            let chunks = try system.start()
            captures.append(Capture(source: .them, chunks: chunks,
                                    description: "system audio (\(system.outputDeviceName), \(system.tapFormat)) as Them",
                                    stop: { system.stop() }))
        }
        return captures
    }

    /// An audio file as "me", in 100 ms chunks at real-time pace, then 2 s of silence (the CLI's `--input`).
    static func file(_ url: URL) throws -> Capture {
        let samples = try AudioFile.load(url) + [Int16](repeating: 0, count: 2 * Wire.sampleRate)
        let (chunks, continuation) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
        let player = Task {
            let clock = ContinuousClock()
            let start = clock.now
            var index = 0
            while index < samples.count, !Task.isCancelled {
                let end = min(index + Wire.sampleRate / 10, samples.count)
                try? await clock.sleep(until: start + .milliseconds(end * 1000 / Wire.sampleRate))  // like a live mic
                continuation.yield(Array(samples[index ..< end]))
                index = end
            }
            continuation.finish()
        }
        let seconds = Double(samples.count) / Double(Wire.sampleRate) - 2
        return Capture(source: .me, chunks: chunks,
                       description: String(format: "%@ (%.1f s) in real time", url.lastPathComponent, seconds),
                       stop: { player.cancel() })
    }
}
