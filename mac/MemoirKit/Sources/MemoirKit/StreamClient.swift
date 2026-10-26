import Foundation

/// A WebSocket session with memoir-asr (`/v1/stream`, bearer token).
public final class StreamClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let decoder = JSONDecoder()

    public init(url: URL, token: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
    }

    /// Opens the socket, sends `start` and waits for `ready` — giving up after `timeout` seconds (a
    /// half-open network can otherwise leave the handshake hanging for a minute).
    public func open(_ start: StartMessage, timeout: Double) async throws -> ServerMessage {
        let timer = Task { [task] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }  // open() then throws
        }
        defer { timer.cancel() }
        return try await open(start)
    }

    /// Opens the socket, sends `start` and waits for `ready`.
    public func open(_ start: StartMessage) async throws -> ServerMessage {
        task.resume()
        let encoder = JSONEncoder()
        let reply: ServerMessage
        do {
            try await task.send(.string(String(decoding: try encoder.encode(start), as: UTF8.self)))
            reply = try await receive()
        } catch let error as URLError where error.code == .notConnectedToInternet {
            // On a working LAN this is macOS Local Network privacy denying the request, not "offline".
            throw MemoirError.localNetworkBlocked(task.originalRequest?.url?.host ?? "the server")
        }
        if reply.type == "error" { throw MemoirError.server(code: reply.code ?? "?", message: reply.message ?? "") }
        guard reply.type == "ready" else { throw MemoirError.unexpectedMessage }
        let serverProtocol = reply.protocolVersion ?? 1  // servers before 0.3 don't say: they speak 1
        guard serverProtocol == Wire.protocolVersion else {
            throw MemoirError.protocolMismatch(server: serverProtocol, client: Wire.protocolVersion)
        }
        return reply
    }

    public func sendAudio(source: Source, frame: Framer.Frame) async throws {
        try await task.send(.data(Wire.audioFrame(source: source, sampleOffset: frame.offset, samples: frame.samples)))
    }

    public func sendStop() async throws {
        try await task.send(.string(#"{"type":"stop"}"#))
    }

    /// Any JSON message (note, meta).
    public func send(_ message: some Encodable & Sendable) async throws {
        try await task.send(.string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)))
    }

    public func receive() async throws -> ServerMessage {
        switch try await task.receive() {
        case .string(let text): return try decoder.decode(ServerMessage.self, from: Data(text.utf8))
        case .data(let data): return try decoder.decode(ServerMessage.self, from: data)
        @unknown default: throw MemoirError.unexpectedMessage
        }
    }

    /// A WebSocket ping: true if the pong came back within `timeout` seconds.
    public func ping(timeout: Double) async -> Bool {
        let answered = Once()
        return await withCheckedContinuation { continuation in
            task.sendPing { error in
                if answered.claim() { continuation.resume(returning: error == nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if answered.claim() { continuation.resume(returning: false) }
            }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Whether trying again could help: not for a wrong token or a protocol mismatch.
    public static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case MemoirError.server(let code, _): code == "busy"
        case MemoirError.protocolMismatch, MemoirError.missingToken: false
        default: true
        }
    }
}

/// Lets exactly one of several callbacks through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
