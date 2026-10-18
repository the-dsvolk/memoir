import Foundation
import Testing
@testable import MemoirKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func read(_ url: URL, _ file: String) throws -> String {
    try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
}

private let oct18 = DateComponents(calendar: .current, year: 2026, month: 10, day: 18, hour: 14, minute: 30).date!

@Test func slugAndFolderName() {
    #expect(MeetingStore.slug("Weekly Sync / Q4") == "weekly-sync-q4")
    #expect(MeetingStore.slug("  ../Café: plan!  ") == "café-plan")
    #expect(MeetingStore.slug("///") == "")
    #expect(MeetingStore.folderName(date: oct18, name: "Weekly Sync") == "2026-10-18_weekly-sync")
    #expect(MeetingStore.folderName(date: oct18, name: "") == "2026-10-18_untitled-call-1430")
}

@Test func storeWritesTheCallFolder() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try MeetingStore(saveDir: dir, name: "Weekly Sync", context: "agenda: Q4",
                                 sources: [.me, .them], client: "test", startedAt: oct18)
    #expect(store.folder.lastPathComponent == "2026-10-18_weekly-sync")
    let perms = try FileManager.default.attributesOfItem(atPath: store.folder.path)[.posixPermissions] as? Int
    #expect(perms == 0o700)

    try store.record(final: .init(type: "final", source: "them", seg: 0, text: "Hi all", t0: 1))
    try store.record(final: .init(type: "final", source: "me", seg: 0, text: "Hello.", t0: 3))
    try store.record(final: .init(type: "final", source: "them", seg: 0, text: "Hi all.", t0: 1))  // amended
    try store.addQuickNote(at: 65, "ask about budget")
    try store.finish(serverPath: "meetings/x.jsonl")

    #expect(try read(store.folder, "transcript.txt") == "[00:01] Them: Hi all.\n[00:03] Me: Hello.\n")
    #expect(try read(store.folder, "transcript.jsonl").split(separator: "\n").count == 3)
    let notes = try read(store.folder, "notes.md")
    #expect(notes.contains("# Weekly Sync") && notes.contains("agenda: Q4") && notes.contains("- [01:05] ask about budget"))
    let meeting = try JSONSerialization.jsonObject(with: Data(try read(store.folder, "meeting.json").utf8)) as? [String: Any]
    #expect(meeting?["name"] as? String == "Weekly Sync")
    #expect(meeting?["sources"] as? [String] == ["me", "them"])
    #expect(meeting?["server_backup"] as? String == "meetings/x.jsonl")
    #expect(meeting?["ended_at"] != nil)
}

@Test func sameNameSameDayGetsASuffixAndRenameMovesTheFolder() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try MeetingStore(saveDir: dir, name: "Sync", sources: [.me], client: "test", startedAt: oct18)
    let second = try MeetingStore(saveDir: dir, name: "Sync", sources: [.me], client: "test", startedAt: oct18)
    #expect(second.folder.lastPathComponent == "2026-10-18_sync_2")

    try second.record(final: .init(type: "final", source: "me", seg: 0, text: "Before rename.", t0: 0))
    try second.rename(to: "Planning")
    #expect(second.folder.lastPathComponent == "2026-10-18_planning")
    try second.record(final: .init(type: "final", source: "me", seg: 1, text: "After rename.", t0: 5))  // open file follows
    try second.finish(serverPath: nil)
    #expect(try read(second.folder, "transcript.jsonl").split(separator: "\n").count == 2)
    #expect(try read(second.folder, "notes.md").hasPrefix("# Planning"))

    try second.rename(to: "Planning")  // same name: stays put
    #expect(second.folder.lastPathComponent == "2026-10-18_planning")
    try first.finish(serverPath: nil)
}

@Test func emptyCallFolderIsDiscarded() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let unused = try MeetingStore(saveDir: dir, name: "No server", sources: [.me], client: "test", startedAt: oct18)
    #expect(unused.discardIfEmpty())
    #expect(!FileManager.default.fileExists(atPath: unused.folder.path))

    let used = try MeetingStore(saveDir: dir, name: "Kept", sources: [.me], client: "test", startedAt: oct18)
    try used.record(final: .init(type: "final", source: "me", seg: 0, text: "Something.", t0: 0))
    #expect(!used.discardIfEmpty())
    #expect(FileManager.default.fileExists(atPath: used.folder.path))
}

@Test func configRoundTrip() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("config.toml").path
    #expect(MemoirConfig.load(path: path) == MemoirConfig())  // missing file → defaults

    var config = MemoirConfig()
    config.saveDir = "~/Calls"
    config.saveAudio = true
    try config.save(path: path)
    #expect(MemoirConfig.load(path: path) == config)

    try "save_dir = \"/tmp/x\"  # comment\nsave_audio = false\nunknown = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
    let edited = MemoirConfig.load(path: path)
    #expect(edited.saveDir == "/tmp/x" && !edited.saveAudio && edited.server == MemoirConfig().server)
}

@Test func transcriptModelUpdatesLinesInPlace() {
    var model = TranscriptModel()
    model.apply(.init(type: "partial", source: "me", seg: 0, text: "hel", t0: 0))
    model.apply(.init(type: "partial", source: "them", seg: 0, text: "hi", t0: 1))
    model.apply(.init(type: "partial", source: "me", seg: 0, text: "hello", t0: 0))
    #expect(model.lines.map(\.text) == ["hello", "hi"])
    model.apply(.init(type: "final", source: "me", seg: 0, text: "Hello.", t0: 0))
    model.apply(.init(type: "partial", source: "me", seg: 0, text: "stale"))  // never downgrades a final
    model.apply(.init(type: "partial", source: "them", seg: 0, text: ""))  // abandoned partial goes away
    #expect(model.lines.map(\.text) == ["Hello."])
    #expect(model.lines.first?.isFinal == true)
}
