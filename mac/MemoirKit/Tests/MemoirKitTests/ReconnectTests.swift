import Foundation
import Network
import Testing
@testable import MemoirKit

// MARK: - Timeline and history

@Test func timelineMapsEachConnectionOntoTheCall() {
    var timeline = Timeline()
    let first = Timeline.Link()
    _ = timeline.map(.init(type: "final", source: "me", seg: 0, text: "one.", t0: 0), link: first)
    var final = ServerMessage(type: "final", source: "me", seg: 1, text: "two.", t0: 0.5)
    final.t1 = 1.0
    #expect(timeline.map(final, link: first).t1 == 1.0)
    _ = timeline.map(.init(type: "partial", source: "me", seg: 2, text: "thr", t0: 1.0), link: first)
    #expect(timeline.lastFinalEnd["me"] == 16_000)

    // The connection drops: the open partial is cleared, the next connection re-sends from 1.0 s.
    let cleared = timeline.dropOpenPartials()
    #expect(cleared.map(\.seg) == [2] && cleared.allSatisfy { $0.text == "" })
    let second = timeline.nextLink(held: ["me": 12_000])
    #expect(second == Timeline.Link(bases: ["me": 16_000], segBase: 3))
    var resent = ServerMessage(type: "final", source: "me", seg: 0, text: "three.", t0: 0)
    resent.t1 = 0.5
    resent.upto = 0.5
    let mapped = timeline.map(resent, link: second)
    #expect(mapped.seg == 3 && mapped.t0 == 1.0 && mapped.t1 == 1.5 && mapped.upto == 1.5)
    #expect(timeline.lastFinalEnd["me"] == 24_000)
    #expect(timeline.nextLink(held: ["me": 30_000]).bases["me"] == 30_000)  // older audio already let go
}

@Test func audioHistoryKeepsWhatANewConnectionNeeds() {
    var history = AudioHistory()
    history.append((0 ..< 1000).map { Int16($0) }, keepFrom: 0, limit: 10_000)
    #expect(history.start == 0 && history.end == 1000)
    history.append((1000 ..< 2000).map { Int16($0) }, keepFrom: 600, limit: 10_000)  // a line ended at 600
    #expect(history.start == 600 && history.samples(from: 600).first == 600)
    #expect(history.samples(from: 1500).first == 1500 && history.samples(from: 0).first == 600)
    history.append((2000 ..< 3000).map { Int16($0) }, keepFrom: 600, limit: 1_500)  // capped
    #expect(history.start == 1500 && history.end == 3000 && history.samples(from: 0).count == 1500)
    for n in 3 ..< 60 { history.append([Int16](repeating: Int16(n), count: 1000), keepFrom: UInt64(n * 1000), limit: 100_000) }
    #expect(history.start == 59_000 && history.samples(from: 0) == [Int16](repeating: 59, count: 1000))  // compacted
}

// MARK: - Against a fake memoir-asr

/// A WebSocket server on 127.0.0.1 standing in for memoir-asr, scripted per connection: refuse it,
/// drop it after so much audio, or serve it — a final for every `lineSamples` samples of "me" (and a
/// partial for the next line), `stopped` after `stop`. Records the first sample each connection received.
final class FakeASRServer: @unchecked Sendable {
    let lineSamples: Int
    private let refuse: @Sendable (Int) -> String?
    private let dropAfter: @Sendable (Int) -> Int?
    private let queue = DispatchQueue(label: "fake-asr")
    private let listener: NWListener
    private let lock = NSLock()
    private var connections = 0
    private var firstSamples: [Int: Int16] = [:]
    private(set) var port: UInt16 = 0

    init(lineSamples: Int = 8000, refuse: @escaping @Sendable (Int) -> String? = { _ in nil },
         dropAfter: @escaping @Sendable (Int) -> Int? = { _ in nil }) throws {
        self.lineSamples = lineSamples
        self.refuse = refuse
        self.dropAfter = dropAfter
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)/v1/stream")! }
    var connectionCount: Int { lock.withLock { connections } }
    func firstSample(of connection: Int) -> Int16? { lock.withLock { firstSamples[connection] } }

    private final class State: @unchecked Sendable {  // used only on `queue`
        var received = 0, lineStart = 0, seg = 0
    }

    private func accept(_ connection: NWConnection) {
        let index = lock.withLock { () -> Int in
            defer { connections += 1 }
            return connections
        }
        connection.start(queue: queue)
        receive(connection, index: index, state: State())
    }

    private func receive(_ connection: NWConnection, index: Int, state: State) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let data else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .text {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                switch json["type"] as? String {
                case "start":
                    if let code = refuse(index) {
                        send(connection, ["type": "error", "code": code, "message": "refused"]) { connection.cancel() }
                        return
                    }
                    send(connection, ["type": "ready", "model": "fake", "chunk_ms": 560, "protocol": 1])
                case "stop":
                    if state.received > state.lineStart { line(connection, state) }
                    send(connection, ["type": "stopped", "path": "fake-\(index).jsonl"]) { connection.cancel() }
                    return
                default: break
                }
            } else if metadata?.opcode == .binary, data.count > Wire.headerSize {
                let samples = (data.count - Wire.headerSize) / 2
                if state.received == 0 {
                    let first = Int16(littleEndian: data.subdata(in: 12 ..< 14).withUnsafeBytes { $0.load(as: Int16.self) })
                    lock.withLock { firstSamples[index] = first }
                }
                state.received += samples
                if let limit = dropAfter(index), state.received >= limit {
                    connection.forceCancel()  // like macOS aborting it: no goodbye
                    return
                }
                if state.received - state.lineStart >= lineSamples {
                    line(connection, state)
                    send(connection, ["type": "partial", "source": "me", "seg": state.seg,
                                      "t0": Double(state.lineStart) / 16_000, "text": "next"])
                }
            }
            receive(connection, index: index, state: state)
        }
    }

    private func line(_ connection: NWConnection, _ state: State) {
        send(connection, ["type": "final", "source": "me", "seg": state.seg, "t0": Double(state.lineStart) / 16_000,
                          "t1": Double(state.received) / 16_000, "text": "line \(state.seg)."])
        state.seg += 1
        state.lineStart = state.received
    }

    private func send(_ connection: NWConnection, _ object: [String: Any], then: (@Sendable () -> Void)? = nil) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in then?() })
    }
}

/// `seconds` of "me" audio whose every sample is its index in the call (mod 30000), in 100 ms chunks.
private func countingCapture(seconds: Double, pace: Duration = .milliseconds(20)) -> Capture {
    let total = Int(seconds * 16_000)
    let (chunks, continuation) = AsyncStream.makeStream(of: [Int16].self, bufferingPolicy: .unbounded)
    let task = Task {
        var index = 0
        while index < total, !Task.isCancelled {
            let end = min(index + 1600, total)
            continuation.yield((index ..< end).map { Int16($0 % 30_000) })
            index = end
            try? await Task.sleep(for: pace)
        }
        continuation.finish()
    }
    return Capture(source: .me, chunks: chunks, description: "counting", stop: { task.cancel() })
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SessionEvent] = []
    func append(_ event: SessionEvent) { lock.withLock { all.append(event) } }
    var events: [SessionEvent] { lock.withLock { all } }
}

/// Runs a session against `server` until it ends (or `timeout`), returning everything it reported.
private func runSession(_ server: FakeASRServer, seconds: Double, finishGrace: Double = 20) async throws -> [SessionEvent] {
    let session = MeetingSession(options: SessionOptions(server: server.url, token: "t", sources: [.me], name: "test",
                                                         app: "memoir-test", echoGate: false))
    session.captureOverride = { [countingCapture(seconds: seconds)] }
    session.retryDelays = [0.05, 0.1]
    session.finishGrace = finishGrace
    session.pingInterval = 60
    let events = try await session.start()
    let log = EventLog()
    await withTaskGroup(of: Void.self) { group in
        group.addTask { for await event in events { log.append(event) } }
        group.addTask { try? await Task.sleep(for: .seconds(15)) }
        _ = await group.next()
        group.cancelAll()
    }
    return log.events
}

private func finals(_ events: [SessionEvent]) -> [ServerMessage] {
    events.compactMap { if case .message(let m) = $0, m.type == "final" { m } else { nil } }.sorted { $0.t0! < $1.t0! }
}

private func count(_ events: [SessionEvent], _ match: (SessionEvent) -> Bool) -> Int { events.filter(match).count }

@Test func reconnectsAndResendsFromTheLastFinishedLine() async throws {
    // The first connection dies after 1.5 s of audio, having finished lines up to 1.0 s.
    let server = try FakeASRServer(dropAfter: { $0 == 0 ? 24_000 : nil })
    let events = try await runSession(server, seconds: 3)

    #expect(count(events) { if case .reconnecting = $0 { true } else { false } } == 1)
    #expect(count(events) { if case .reconnected = $0 { true } else { false } } == 1)
    #expect(count(events) { if case .stopped = $0 { true } else { false } } == 1)
    #expect(server.connectionCount == 2)
    #expect(server.firstSample(of: 1) == 16_000)  // re-sent from the end of the last finished line

    let lines = finals(events)
    #expect(lines.first?.t0 == 0)
    #expect(abs((lines.last?.t1 ?? 0) - 3.0) < 0.001)  // the whole call, nothing lost
    for (a, b) in zip(lines, lines.dropFirst()) { #expect(abs(a.t1! - b.t0!) < 0.001) }  // no gaps, no overlaps
    #expect(Set(lines.compactMap(\.seg)).count == lines.count)  // segment numbers don't collide
    let cleared = events.contains { if case .message(let m) = $0 { m.type == "partial" && m.text == "" } else { false } }
    #expect(cleared)  // the dropped connection's unfinished line was taken off the views
}

@Test func waitsOutABusyServer() async throws {
    // After the drop the server still has the old meeting for a moment: "busy", then it takes us.
    let server = try FakeASRServer(refuse: { $0 == 1 ? "busy" : nil }, dropAfter: { $0 == 0 ? 16_000 : nil })
    let events = try await runSession(server, seconds: 2)
    #expect(server.connectionCount == 3)
    #expect(count(events) { if case .reconnected = $0 { true } else { false } } == 1)
    #expect(abs((finals(events).last?.t1 ?? 0) - 2.0) < 0.001)
}

@Test func givesUpWhenRetryingCantHelp() async throws {
    let server = try FakeASRServer(refuse: { $0 >= 1 ? "unauthorized" : nil }, dropAfter: { $0 == 0 ? 8_000 : nil })
    let events = try await runSession(server, seconds: 3)
    let failure = events.compactMap { if case .failed(let message) = $0 { message } else { nil } }.first
    #expect(failure?.contains("unauthorized") == true)
    #expect(server.connectionCount == 2)
}

@Test func stopWithoutAServerStillEnds() async throws {
    // Dropped, then busy for good: after Stop it tries `finishGrace` longer, then ends as stopped.
    let server = try FakeASRServer(refuse: { $0 >= 1 ? "busy" : nil }, dropAfter: { $0 == 0 ? 8_000 : nil })
    let started = Date()
    let events = try await runSession(server, seconds: 1, finishGrace: 0.5)
    #expect(count(events) { if case .stopped = $0 { true } else { false } } == 1)
    #expect(count(events) { if case .failed = $0 { true } else { false } } == 0)
    #expect(Date().timeIntervalSince(started) < 5)
}
