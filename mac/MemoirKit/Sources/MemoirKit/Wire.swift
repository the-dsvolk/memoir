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

    /// "Me", "Them", "Room".
    public var label: String { name.prefix(1).uppercased() + name.dropFirst() }
}

public enum Wire {
    public static let sampleRate = 16_000
    public static let headerSize = 12
    /// The wire protocol's version, separate from memoir's: bumped only when messages or frames change
    /// incompatibly, so a mismatched app and server fail with a clear message (DESIGN.md §6).
    public static let protocolVersion = 1

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
    public let prep: String
    public let app: String
    public let sources: [String]
    public let sampleRate = Wire.sampleRate
    public let encoding = "pcm_s16le"
    public let protocolVersion = Wire.protocolVersion
    public let clientVersion = MemoirVersion.current.display

    public init(meetingId: String, title: String, prep: String = "", app: String = "", sources: [Source]) {
        self.meetingId = meetingId
        self.title = title
        self.prep = prep
        self.app = app
        self.sources = sources.map(\.name)
    }

    enum CodingKeys: String, CodingKey {
        case type, title, prep, app, sources, encoding
        case meetingId = "meeting_id"
        case sampleRate = "sample_rate"
        case protocolVersion = "protocol"
        case clientVersion = "client_version"
    }
}

/// Prep added during the call; `t` is the meeting clock in seconds.
public struct PrepMessage: Encodable, Sendable {
    public let type = "prep"
    public let t: Double
    public let text: String

    enum CodingKeys: String, CodingKey { case type, t, text }
}

/// A quick note typed during the call; `t` is the meeting clock in seconds.
public struct NoteMessage: Encodable, Sendable {
    public let type = "note"
    public let id: String
    public let t: Double
    public let text: String

    enum CodingKeys: String, CodingKey { case type, id, t, text }
}

/// The call was renamed during the call.
public struct MetaMessage: Encodable, Sendable {
    public let type = "meta"
    public let title: String

    enum CodingKeys: String, CodingKey { case type, title }
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
    public var serverVersion: String?  // in `ready`, from servers since 0.3
    public var protocolVersion: Int?  // in `ready`; absent = 1

    public init(type: String, source: String? = nil, seg: Int? = nil, text: String? = nil, t0: Double? = nil) {
        self.type = type
        self.source = source
        self.seg = seg
        self.text = text
        self.t0 = t0
    }

    enum CodingKeys: String, CodingKey {
        case type, source, seg, t0, t1, text, upto, model, path, code, message
        case chunkMs = "chunk_ms"
        case serverVersion = "server_version"
        case protocolVersion = "protocol"
    }
}
