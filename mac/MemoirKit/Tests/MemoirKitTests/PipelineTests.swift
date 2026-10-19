import Foundation
import Testing
@testable import MemoirKit

// MARK: - TOML

@Test func tomlReadsThePipelineShapes() throws {
    let doc = try TOML.parse("""
        # memoir pipeline
        min_finals = 3
        login_shell = false

        [[step]]
        id = "a"
        run = ["echo", "x # not a comment", 'C:\\raw']  # comment after a value
        keychain = { KEY = "svc", "quoted key" = "v" }
        [step.env]
        FOO = "tab\\there \\u00e9"

        [[step]]
        id = "b"
        needs = [
          "a",  # trailing comma is fine
        ]
        timeout = 1_000
        ratio = 0.5
        """)
    #expect(doc["min_finals"] == .integer(3))
    #expect(doc["login_shell"] == .bool(false))
    let steps = try #require(doc["step"]?.array)
    #expect(steps.count == 2)
    let a = try #require(steps[0].table)
    #expect(a["run"] == .array([.string("echo"), .string("x # not a comment"), .string("C:\\raw")]))
    #expect(a["keychain"] == .table(["KEY": .string("svc"), "quoted key": .string("v")]))
    #expect(a["env"] == .table(["FOO": .string("tab\there é")]))
    let b = try #require(steps[1].table)
    #expect(b["needs"] == .array([.string("a")]))
    #expect(b["timeout"] == .integer(1000))
    #expect(b["ratio"] == .float(0.5))
}

@Test func tomlReportsErrorsWithTheLine() {
    #expect(throws: TOMLError(line: 2, message: "a is defined twice")) { try TOML.parse("a = 1\na = 2") }
    #expect(throws: TOMLError.self) { try TOML.parse("x = bare") }
    #expect(throws: TOMLError.self) { try TOML.parse("s = \"abc\nt = 1") }
    #expect(throws: TOMLError.self) { try TOML.parse("[[step]]\nid = \"a\"\n[step]") }
    #expect(throws: TOMLError.self) { try TOML.parse("a = 1 b = 2") }
}

// MARK: - Config

private let twoSteps = """
    min_finals = 2
    login_shell = false

    [[step]]
    id = "doc"
    label = "Google Doc"
    needs = ["summary"]
    run = ["publish", "{call}/summary.md"]
    default = false

    [[step]]
    id = "summary"
    label = "Summary"
    run = ["summarize", "{call}"]
    cwd = "~/somewhere"
    outputs = ["summary.md"]
    keychain = { API_KEY = "api-key" }
    timeout = 60

    [[step]]
    id = "index"
    run = ["index-locally"]
    remote = false
    """

@Test func pipelineConfigParsesAndOrdersSteps() throws {
    let config = try PipelineConfig.parse(twoSteps)
    #expect(config.steps.map(\.id) == ["summary", "doc", "index"])  // needs first
    #expect(config.minFinals == 2)
    #expect(config.loginShell == false)
    let summary = try #require(config.step("summary"))
    #expect(summary.label == "Summary")
    #expect(summary.keychain == ["API_KEY": "api-key"])
    #expect(summary.timeout == 60)
    #expect(summary.remote)  // remote unless a step says otherwise
    #expect(config.step("index")?.label == "index")
    #expect(config.step("doc")?.enabledByDefault == false)

    #expect(config.defaultSteps() == ["summary", "index"])
    #expect(config.selection(["doc"]) == ["summary", "doc"])  // with what it needs
    #expect(config.selection(["doc", "index"], keepLocal: true) == ["index"])
    #expect(config.dependents(of: "summary") == ["doc"])
}

@Test func pipelineConfigRejectsMistakes() {
    #expect(throws: PipelineConfigError("a needs b, which isn't a step")) {
        try PipelineConfig.parse("[[step]]\nid = \"a\"\nrun = [\"x\"]\nneeds = [\"b\"]")
    }
    #expect(throws: PipelineConfigError("steps need each other in a loop: a, b")) {
        try PipelineConfig.parse("[[step]]\nid = \"a\"\nrun = [\"x\"]\nneeds = [\"b\"]\n[[step]]\nid = \"b\"\nrun = [\"x\"]\nneeds = [\"a\"]")
    }
    #expect(throws: PipelineConfigError("unknown setting comand in a")) {
        try PipelineConfig.parse("[[step]]\nid = \"a\"\ncomand = [\"x\"]")
    }
    #expect(throws: PipelineConfigError("a: run needs a command")) { try PipelineConfig.parse("[[step]]\nid = \"a\"\nrun = []") }
    #expect(throws: PipelineConfigError("two steps are called a")) {
        try PipelineConfig.parse("[[step]]\nid = \"a\"\nrun = [\"x\"]\n[[step]]\nid = \"a\"\nrun = [\"y\"]")
    }
}

// MARK: - Runner

private func makeCall(name: String = "Weekly Sync") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-pipeline-\(UUID().uuidString)")
    let store = try MeetingStore(saveDir: dir, name: name, sources: [.me], client: "test",
                                 postprocess: PostprocessChoice(steps: ["write"], keepLocal: false))
    try store.record(final: .init(type: "final", source: "me", seg: 0, text: "Hello.", t0: 1))
    try store.finish(serverPath: nil)
    return store.folder
}

private func sh(_ id: String, _ script: String, needs: [String] = [], outputs: [String] = [],
                timeout: TimeInterval = 30) -> PipelineStep {
    var step = PipelineStep(id: id, label: id.capitalized, run: ["/bin/sh", "-c", script])
    step.needs = needs
    step.outputs = outputs
    step.timeout = timeout
    return step
}

private func pipeline(_ steps: PipelineStep...) throws -> PipelineConfig {
    var config = try PipelineConfig(steps: steps)
    config.loginShell = false
    return config
}

@Test func runnerRunsStepsAndKeepsTheirResults() async throws {
    let call = try makeCall()
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    let config = try pipeline(
        sh("write", "echo \"summary of {name} on {date}\" > summary.md; echo \"$MEMOIR_STEP in $MEMOIR_CALL_DIR\"",
           outputs: ["summary.md"]),
        sh("link", "echo making a doc; echo 'https://docs.example.com/d/abc'", needs: ["write"]))
    let state = try await PipelineRunner(config: config, call: call).run(steps: ["link"])

    #expect(state.steps["write"]?.status == .ok)
    #expect(state.steps["write"]?.outputs == ["summary.md"])
    #expect(state.steps["link"]?.status == .ok)
    #expect(state.steps["link"]?.url == "https://docs.example.com/d/abc")
    let summary = try String(contentsOf: call.appendingPathComponent("summary.md"), encoding: .utf8)
    #expect(summary.hasPrefix("summary of Weekly Sync on 20"))
    let log = try String(contentsOf: PipelineState.log(call, step: "write"), encoding: .utf8)
    #expect(log.contains("write in \(call.path)"))
    #expect(PipelineState.load(call) == state)  // saved in pipeline/state.json
}

@Test func runnerChecksOutputsWereWrittenNow() async throws {
    let call = try makeCall()
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    let old = call.appendingPathComponent("summary.md")
    try "from an earlier run".write(to: old, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: old.path)

    let config = try pipeline(sh("write", "echo 'run finished: status cancelled'", outputs: ["summary.md"]))
    let state = try await PipelineRunner(config: config, call: call).run(steps: ["write"])
    #expect(state.steps["write"]?.status == .failed)
    #expect(state.steps["write"]?.message == "finished without writing summary.md")
}

@Test func runnerSkipsStepsWhoseNeedsFailed() async throws {
    let call = try makeCall()
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    let config = try pipeline(
        sh("write", "echo working; echo 'startup failed: no key' >&2; exit 3"),
        sh("link", "echo never", needs: ["write"]))
    let state = try await PipelineRunner(config: config, call: call).run(steps: ["link"])
    #expect(state.steps["write"]?.status == .failed)
    #expect(state.steps["write"]?.exitCode == 3)
    #expect(state.steps["write"]?.message == "startup failed: no key (exit 3)")
    #expect(state.steps["link"]?.status == .skipped)
    #expect(state.steps["link"]?.message == "needs Write, which didn't finish")
}

@Test func runnerReusesSucceededStepsUnlessForced() async throws {
    let call = try makeCall()
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    let config = try pipeline(
        sh("write", "date +%s%N >> runs.txt; echo x > summary.md", outputs: ["summary.md"]),
        sh("link", "echo https://example.com/$(wc -l < runs.txt | tr -d ' ')", needs: ["write"]))
    let first = try await PipelineRunner(config: config, call: call).run(steps: ["link"])
    #expect(first.steps["link"]?.url == "https://example.com/1")

    let again = try await PipelineRunner(config: config, call: call).run(steps: ["link"])
    #expect(again == PipelineState.load(call))
    #expect(again.steps["link"]?.startedAt == first.steps["link"]?.startedAt)  // nothing ran

    let forced = try await PipelineRunner(config: config, call: call).run(steps: ["link"], force: true)
    #expect(forced.steps["link"]?.startedAt != first.steps["link"]?.startedAt)
    #expect(forced.steps["write"]?.startedAt == first.steps["write"]?.startedAt)  // its need is reused

    try FileManager.default.removeItem(at: call.appendingPathComponent("summary.md"))
    let redone = try await PipelineRunner(config: config, call: call).run(steps: ["link"])
    #expect(redone.steps["link"]?.url == "https://example.com/2")  // write ran again: its output was gone
}

@Test func runnerTimesOutSteps() async throws {
    let call = try makeCall()
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    let config = try pipeline(sh("slow", "sleep 30", timeout: 1))
    let started = Date()
    let state = try await PipelineRunner(config: config, call: call).run(steps: ["slow"])
    #expect(state.steps["slow"]?.status == .failed)
    #expect(state.steps["slow"]?.message == "timed out after 1 s")
    #expect(durationText(1800) == "30 min")
    #expect(durationText(123) == "2 min 3 s")
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test func cancelStopsTheWholeStepAndTheRest() async throws {
    let call = try makeCall()
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    // The background sleep keeps the output pipe open: only stopping the process group ends it quickly.
    let config = try pipeline(sh("slow", "sleep 30 & sleep 30; wait"), sh("after", "echo no", needs: ["slow"]))
    let runner = PipelineRunner(config: config, call: call)
    let started = Date()
    let task = Task { try await runner.run(steps: ["after"]) }
    try await Task.sleep(for: .milliseconds(500))
    #expect(PipelineRunner.isBusy(call))
    await #expect(throws: PipelineError("this call is already being processed")) {
        try await PipelineRunner(config: config, call: call).run(steps: ["slow"])
    }
    runner.cancel()
    let state = try await task.value
    #expect(state.steps["slow"]?.status == .cancelled)
    #expect(state.steps["after"]?.status == .cancelled)
    #expect(Date().timeIntervalSince(started) < 2.4)
    #expect(!PipelineRunner.isBusy(call))
}

@Test func runnerRefusesFoldersThatAreNotCalls() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memoir-not-a-call-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = try pipeline(sh("write", "true"))
    await #expect(throws: PipelineError.self) { try await PipelineRunner(config: config, call: dir).run(steps: ["write"]) }
}

// MARK: - Call folders

@Test func callInfoReadsTheChoiceAndTheTranscript() throws {
    let call = try makeCall(name: "Design review")
    defer { try? FileManager.default.removeItem(at: call.deletingLastPathComponent()) }
    let info = try CallInfo.load(call)
    #expect(info.name == "Design review")
    #expect(info.postprocess == PostprocessChoice(steps: ["write"], keepLocal: false))
    #expect(info.finals == 1)
    #expect(info.endedAt != nil)
    #expect(info.day == String(call.lastPathComponent.prefix(10)))
    #expect(CallInfo.recent(in: call.deletingLastPathComponent()).map(\.folder.lastPathComponent) == [call.lastPathComponent])
}
