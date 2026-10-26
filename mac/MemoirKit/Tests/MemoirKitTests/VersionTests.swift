import Foundation
import Testing
@testable import MemoirKit

private func stamped(ahead: Int = 0, modified: Bool = false) -> MemoirVersion {
    MemoirVersion(info: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "42",
                         "MemoirCommit": "3005f27", "MemoirCommitsSinceTag": ahead, "MemoirModified": modified,
                         "MemoirBuildDate": "2026-10-25T18:00:00Z"])
}

@Test func versionDisplay() {
    #expect(stamped().display == "0.2.0")
    #expect(stamped().isRelease)
    #expect(stamped(ahead: 3).display == "0.2.0+3 (3005f27)")
    #expect(stamped(ahead: 3, modified: true).display == "0.2.0+3 (3005f27, modified)")
    #expect(stamped(modified: true).display == "0.2.0 (3005f27, modified)")
    #expect(!stamped(modified: true).isRelease)
    #expect(stamped().build == 42)
    #expect(stamped().buildDate != nil)
    #expect(stamped(ahead: 1).details.contains("1 commit after 0.2.0"))
}

@Test func unstampedBuildsSayDev() {
    let plain = MemoirVersion(info: ["CFBundleShortVersionString": "0.0.0"])  // e.g. swift build, swift test
    #expect(plain.display == "dev")
    #expect(!plain.isStamped && !plain.isRelease)
}

@Test func startCarriesTheProtocolAndClientVersion() throws {
    let data = try JSONEncoder().encode(StartMessage(meetingId: "m", title: "t", sources: [.me]))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["protocol"] as? Int == Wire.protocolVersion)
    #expect(json["client_version"] as? String == MemoirVersion.current.display)
}

@Test func readyCarriesTheServerVersion() throws {
    let ready = try JSONDecoder().decode(ServerMessage.self, from: Data(
        #"{"type":"ready","model":"m","chunk_ms":560,"server_version":"0.3.0","protocol":1}"#.utf8))
    #expect(ready.serverVersion == "0.3.0")
    #expect(ready.protocolVersion == 1)
    let old = try JSONDecoder().decode(ServerMessage.self, from: Data(#"{"type":"ready","model":"m"}"#.utf8))
    #expect(old.serverVersion == nil && old.protocolVersion == nil)
}
