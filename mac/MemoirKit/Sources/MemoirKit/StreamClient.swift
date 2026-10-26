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

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
