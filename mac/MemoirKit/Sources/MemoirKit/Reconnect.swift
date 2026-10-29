import Foundation

// Reconnecting (DESIGN.md §6): when the connection to memoir-asr drops mid-call — on 2026-10-26 it was
// macOS re-applying Local Network policy whenever Jamf re-installed an app — capture goes on, the audio
// is kept, and a new connection re-sends it from the end of the last finished line. The server starts
// every connection from zero, so the Mac maps each connection's times and segment numbers onto the call's.

/// Each connection's numbering, mapped onto the call's.
struct Timeline: Sendable {
    /// Where one connection sits in the call.
    struct Link: Sendable, Equatable {
        /// Per source: the call's sample index of this connection's offset 0.
        var bases: [String: UInt64] = [:]
        /// Added to this connection's segment numbers, so they don't collide with earlier ones.
        var segBase = 0

        func base(_ source: String) -> UInt64 { bases[source] ?? 0 }
    }

    /// Per source: the call's sample index where the last finished line ends — what a new connection
    /// re-sends from, so the line that was in progress is transcribed again rather than lost.
    private(set) var lastFinalEnd: [String: UInt64] = [:]
    private(set) var maxSeg = -1
    /// Lines shown as partials and not finished yet, by "source#seg".
    private var openPartials: [String: ServerMessage] = [:]

    /// A server message in the call's terms: times shifted by the connection's base, segments by its seg base.
    mutating func map(_ msg: ServerMessage, link: Link) -> ServerMessage {
        guard msg.type == "partial" || msg.type == "final" else { return msg }
        var m = msg
        let source = m.source ?? "me"
        let shift = Double(link.base(source)) / Double(Wire.sampleRate)
        m.t0 = m.t0.map { $0 + shift }
        m.t1 = m.t1.map { $0 + shift }
        m.upto = m.upto.map { $0 + shift }
        if let seg = m.seg {
            m.seg = seg + link.segBase
            maxSeg = max(maxSeg, seg + link.segBase)
        }
        let key = "\(source)#\(m.seg ?? -1)"
        if m.type == "final" {
            openPartials[key] = nil
            if let t1 = m.t1 {
                lastFinalEnd[source] = max(lastFinalEnd[source] ?? 0, UInt64((t1 * Double(Wire.sampleRate)).rounded()))
            }
        } else {
            openPartials[key] = m.text?.isEmpty == false ? m : nil
        }
        return m
    }

    /// The next connection: each source re-sent from the end of its last finished line (or from the
    /// oldest audio still held), with segment numbers after every one seen so far.
    func nextLink(held: [String: UInt64]) -> Link {
        Link(bases: held.reduce(into: [:]) { bases, entry in bases[entry.key] = max(entry.value, lastFinalEnd[entry.key] ?? 0) },
             segBase: maxSeg + 1)
    }

    /// The partials of a connection that dropped will never be finished: as empty partials, which
    /// remove them from the transcript views (`TranscriptModel`, `LiveTranscript`).
    mutating func dropOpenPartials() -> [ServerMessage] {
        defer { openPartials.removeAll() }
        return openPartials.values.sorted { ($0.seg ?? 0) < ($1.seg ?? 0) }.map { partial in
            var cleared = partial
            cleared.text = ""
            return cleared
        }
    }
}

/// One source's recent audio, indexed by sample number in the call — what a new connection re-sends.
struct AudioHistory: Sendable {
    private var buffer: [Int16] = []
    private var head = 0  // buffer[head...] is held; compacted now and then, not on every chunk
    /// The call's sample index of the oldest sample held.
    private(set) var start: UInt64 = 0

    /// The call's sample index just after the newest sample.
    var end: UInt64 { start + UInt64(buffer.count - head) }

    /// Adds a chunk, then lets go of what's before `keepFrom` and of anything beyond the newest `limit` samples.
    mutating func append(_ chunk: [Int16], keepFrom: UInt64, limit: Int) {
        buffer.append(contentsOf: chunk)
        let held = buffer.count - head
        var drop = keepFrom > start ? Int(min(keepFrom - start, UInt64(held))) : 0
        drop = max(drop, held - limit)
        if drop > 0 {
            head += drop
            start += UInt64(drop)
        }
        if head > 16_000, head * 2 > buffer.count {  // compact: at most a copy per half buffer
            buffer.removeFirst(head)
            head = 0
        }
    }

    /// The samples from the call's sample index `index` (clamped to what's held) to the newest.
    func samples(from index: UInt64) -> [Int16] {
        let skip = index > start ? Int(min(index - start, UInt64(buffer.count - head))) : 0
        return Array(buffer[(head + skip)...])
    }
}

/// What the session's loop shares with the tasks that read each connection: the timeline and the
/// latency figures, and which connection is the live one (messages from a dropped one are ignored).
final class SessionShared: @unchecked Sendable {
    private let lock = NSLock()
    private var timeline = Timeline()
    private var current = -1
    private var latency = LatencyStats()
    private var reconnectDeadline = Double.infinity

    /// Maps a message from connection `id` and passes it on — unless that connection has been dropped.
    func deliver(_ msg: ServerMessage, from id: Int, link: Timeline.Link, logs: [String: SendLog],
                 chunkSamples: UInt64, to emit: AsyncStream<SessionEvent>.Continuation) {
        lock.withLock {
            guard id == current else { return }
            let mapped = timeline.map(msg, link: link)
            if mapped.type == "partial", mapped.text?.isEmpty == false, let upto = mapped.upto,
               let log = logs[mapped.source ?? "me"] {
                latency.record(upto: upto, log: log, chunkSamples: chunkSamples)
            }
            emit.yield(.message(mapped))  // inside the lock: nothing from a dropped connection gets past
        }
    }

    func activate(_ id: Int) { lock.withLock { current = id } }

    /// Stops listening to the current connection; returns the partials it left unfinished.
    func retire() -> [ServerMessage] {
        lock.withLock {
            current = -1
            return timeline.dropOpenPartials()
        }
    }

    func nextLink(held: [String: UInt64]) -> Timeline.Link { lock.withLock { timeline.nextLink(held: held) } }
    func lastFinalEnd(_ source: String) -> UInt64 { lock.withLock { timeline.lastFinalEnd[source] ?? 0 } }
    var latencyStats: LatencyStats { lock.withLock { latency } }

    /// When reconnecting gives up (uptime seconds).
    var deadline: Double {
        get { lock.withLock { reconnectDeadline } }
        set { lock.withLock { reconnectDeadline = newValue } }
    }
}
