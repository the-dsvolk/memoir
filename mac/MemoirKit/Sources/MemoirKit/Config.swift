import Foundation

/// Settings shared by the app and the CLI: `~/.config/memoir/config.toml` (DESIGN.md §4.7).
/// A tiny TOML subset — `key = "string"` and `key = true|false` — is all it needs.
public struct MemoirConfig: Sendable, Equatable {
    public static let defaultPath = "~/.config/memoir/config.toml"

    public var saveDir = "~/memoir"
    public var saveAudio = false
    public var server = "ws://spark-0e81.local:8770/v1/stream"
    public var tokenFile = "~/.config/memoir/token"

    public init() {}

    /// The config at `path`; defaults for anything missing (or if the file doesn't exist).
    public static func load(path: String = defaultPath) -> MemoirConfig {
        var config = MemoirConfig()
        guard let text = try? String(contentsOfFile: expand(path), encoding: .utf8) else { return config }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.hasPrefix("#"), let value = parseValue(line[line.index(after: eq)...]) else { continue }
            switch (key, value) {
            case ("save_dir", .string(let s)): config.saveDir = s
            case ("save_audio", .bool(let b)): config.saveAudio = b
            case ("server", .string(let s)): config.server = s
            case ("token_file", .string(let s)): config.tokenFile = s
            default: continue
            }
        }
        return config
    }

    public func save(path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: Self.expand(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let text = """
            # memoir settings — shared by Memoir.app and the `memoir` CLI (DESIGN.md §4.7)
            save_dir   = \(Self.quote(saveDir))
            save_audio = \(saveAudio)
            server     = \(Self.quote(server))
            token_file = \(Self.quote(tokenFile))

            """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public var saveDirectory: URL { URL(fileURLWithPath: Self.expand(saveDir), isDirectory: true) }

    /// The server's bearer token: `MEMOIR_TOKEN`, else the token file.
    public func token() throws -> String {
        if let env = ProcessInfo.processInfo.environment["MEMOIR_TOKEN"], !env.isEmpty { return env }
        let text = try? String(contentsOfFile: Self.expand(tokenFile), encoding: .utf8)
        guard let token = text?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw MemoirError.missingToken(Self.expand(tokenFile))
        }
        return token
    }

    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private enum Value { case string(String), bool(Bool) }

    private static func parseValue(_ raw: Substring) -> Value? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return .string(String(body[..<end]).replacingOccurrences(of: "\\\\", with: "\\"))
        }
        let bare = value.split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return nil
        }
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "") + "\""
    }
}
