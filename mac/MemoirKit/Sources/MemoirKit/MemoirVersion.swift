import Foundation

/// Which build of memoir this is (DESIGN.md §9.1). `scripts/version.sh` stamps it into the Info.plist at
/// build time — the app's own, or the one `scripts/build-cli.sh` embeds in the CLI — from the last
/// `vX.Y.Z` tag. A plain `swift build` isn't stamped: it says "dev".
public struct MemoirVersion: Sendable, Equatable {
    /// The last release, "0.2.0"; "dev" when the build wasn't stamped.
    public var version: String
    /// Commits in the history — what macOS shows in parentheses (CFBundleVersion).
    public var build: Int
    /// Commits after the release tag (0 = exactly the release).
    public var commitsSinceTag: Int
    public var commit: String?
    /// Built with uncommitted changes.
    public var modified: Bool
    public var buildDate: Date?

    public static let current = MemoirVersion(info: Bundle.main.infoDictionary ?? [:])

    public init(info: [String: Any]) {
        commit = info["MemoirCommit"] as? String
        let stamped = commit != nil
        version = stamped ? info["CFBundleShortVersionString"] as? String ?? "0.0.0" : "dev"
        build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        commitsSinceTag = info["MemoirCommitsSinceTag"] as? Int ?? 0
        modified = info["MemoirModified"] as? Bool ?? false
        buildDate = (info["MemoirBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public var isStamped: Bool { commit != nil }

    /// Exactly a release: tagged and unmodified.
    public var isRelease: Bool { isStamped && commitsSinceTag == 0 && !modified }

    /// `0.2.0` · `0.2.0+3 (3005f27)` · `0.2.0+3 (3005f27, modified)` · `dev`.
    public var display: String {
        guard let commit else { return "dev" }
        if isRelease { return version }
        let base = commitsSinceTag > 0 ? "\(version)+\(commitsSinceTag)" : version
        return "\(base) (\(commit)\(modified ? ", modified" : ""))"
    }

    /// Lines for About, `memoir --version` and bug reports.
    public var details: [String] {
        guard let commit else { return ["unstamped build — use scripts/build-cli.sh or Xcode for a version"] }
        var lines = ["build \(build), commit \(commit)" + (modified ? " with uncommitted changes" : "")]
        if commitsSinceTag > 0 {
            lines.append("\(commitsSinceTag) commit\(commitsSinceTag == 1 ? "" : "s") after \(version)")
        }
        if let buildDate { lines.append("built \(buildDate.formatted(date: .abbreviated, time: .shortened))") }
        return lines
    }
}
