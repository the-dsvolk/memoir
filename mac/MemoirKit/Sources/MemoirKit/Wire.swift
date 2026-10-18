import Foundation

/// Audio sources (DESIGN.md §6). The raw value is the first byte of every audio frame.
public enum Source: UInt8, Sendable {
    case me = 0, them = 1, room = 2

    public var name: String {
        switch self {
        case .me: "me"
        case .them: "them"
        case .room: "room"
        }
    }
}

public enum Wire {
    public static let sampleRate = 16_000
    public static let headerSize = 12

    /// 12-byte header — source (u8), 3 reserved bytes, sample offset (u64 LE) — then PCM s16le.
    public static func audioFrame(source: Source, sampleOffset: UInt64, samples: [Int16]) -> Data {
        var data = Data(capacity: headerSize + 2 * samples.count)
        data.append(source.rawValue)
        data.append(contentsOf: [0, 0, 0])
        withUnsafeBytes(of: sampleOffset.littleEndian) { data.append(contentsOf: $0) }
        // Apple silicon and Intel Macs are little-endian, so the samples go out as they are.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

/// The client's first message.
public struct StartMessage: Encodable, Sendable {
    public let type = "start"
    public let meetingId: String
    public let title: String
    public let app: String
    public let sources: [String]
    public let sampleRate = Wire.sampleRate
    public let encoding = "pcm_s16le"

    public init(meetingId: String, title: String, app: String = "", sources: [Source]) {
        self.meetingId = meetingId
        self.title = title
        self.app = app
        self.sources = sources.map(\.name)
    }

    enum CodingKeys: String, CodingKey {
        case type, title, app, sources, encoding
        case meetingId = "meeting_id"
        case sampleRate = "sample_rate"
    }
}

/// Any message from the server: ready, partial, final, stopped or error.
public struct ServerMessage: Decodable, Sendable, Equatable {
    public let type: String
    public var source: String?
    public var seg: Int?
    public var t0: Double?
    public var t1: Double?
    public var text: String?
    public var upto: Double?
    public var model: String?
    public var chunkMs: Int?
    public var path: String?
    public var code: String?
    public var message: String?

    public init(type: String, seg: Int? = nil, text: String? = nil, t0: Double? = nil) {
        self.type = type
        self.seg = seg
        self.text = text
        self.t0 = t0
    }

    enum CodingKeys: String, CodingKey {
        case type, source, seg, t0, t1, text, upto, model, path, code, message
        case chunkMs = "chunk_ms"
    }
}
