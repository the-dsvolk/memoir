import AppKit
import MemoirKit
import Observation
import SwiftUI

/// The app's state: one call at a time, run by `MeetingSession` and recorded by `MeetingStore` — the
/// same core the CLI uses (D13) — then the after-the-call pipeline on finished calls (DESIGN.md §4.8).
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, connecting, waitingForNetwork, live, stopping
        case reconnecting(String)  // the connection dropped (why); still recording
        case failed(String)
    }

    struct QuickNote: Identifiable, Equatable {
        let id = UUID()
        let t: Double  // meeting clock, seconds
        let text: String
    }

    /// Pipeline steps to run on one call; jobs run one at a time.
    struct PipelineJob: Equatable {
        let folder: URL
        let steps: [String]
        let force: Bool
        let title: String
    }

    struct RecentCall: Identifiable {
        let info: CallInfo
        let state: PipelineState?
        var id: String { info.id }
    }

    var status: Status = .idle
    var config = MemoirConfig.load()
    var transcript = TranscriptModel()
    var callName = ""
    var prep = ""  // prep written before the call
    var source = UserDefaults.standard.string(forKey: "source") ?? "mic+system"
    var folder: URL?
    var startedAt: Date?
    var serverInfo = ""
    /// memoir-asr's version, as of the last call ("before 0.3" if it didn't say); nil before any call.
    var serverVersion = UserDefaults.standard.string(forKey: "lastServerVersion")
    var capturing = ""
    var silenceHint = false
    var lastSummary = ""
    var overlayVisible = false
    var quickNotes: [QuickNote] = []
    var prepAdditions: [QuickNote] = []  // prep added during the call (append-only, timestamped)

    // After the call (DESIGN.md §4.8)
    var pipeline: PipelineConfig?
    var pipelineError: String?
    /// What the current (or last) call runs when it stops — chosen in New Call.
    var choice = PostprocessChoice(steps: [])
    /// Live pipeline state, by call folder path.
    var pipelineStates: [String: PipelineState] = [:]
    /// Calls not processed automatically because they were short: folder path → finished lines.
    var tooShort: [String: Int] = [:]
    /// Jobs that couldn't start (no pipeline, already running elsewhere…): folder path → why.
    var processingErrors: [String: String] = [:]
    var activeJob: PipelineJob?
    var queue: [PipelineJob] = []
    var recentCalls: [RecentCall] = []

    /// The meeting clock (seconds since the server said ready), for note timestamps.
    var elapsed: Double { session?.elapsed ?? 0 }

    @ObservationIgnored private var session: MeetingSession?
    @ObservationIgnored private var store: MeetingStore?
    @ObservationIgnored private var lastStore: MeetingStore?  // the finished call, for renaming it afterwards
    @ObservationIgnored private var runner: PipelineRunner?
    @ObservationIgnored private let overlay = OverlayController()

    init() {
        Notifier.shared.start()
        loadPipeline()
        refreshRecent()
    }

    var isRecording: Bool {
        switch status {
        case .connecting, .waitingForNetwork, .live, .stopping, .reconnecting: true
        case .idle, .failed: false
        }
    }

    /// A connection drop not recovered from yet: when (meeting clock) and why — for `meeting.json`.
    @ObservationIgnored private var dropped: (t: Double, reason: String)?

    var sources: [Source] {
        switch source {
        case "mic": [.me]
        case "system": [.them]
        default: [.me, .them]
        }
    }

    func start(name: String, prep: String, source: String, choice: PostprocessChoice? = nil) async {
        guard !isRecording else { return }
        self.source = source
        UserDefaults.standard.set(source, forKey: "source")
        callName = name
        self.prep = prep
        if let choice { self.choice = choice }
        transcript.clear()
        quickNotes.removeAll()
        prepAdditions.removeAll()
        silenceHint = false
        lastSummary = ""
        startedAt = nil
        status = .connecting
        config = MemoirConfig.load()
        showOverlay()

        var store: MeetingStore?
        do {
            guard let server = URL(string: config.server) else { throw AppError("bad server URL \(config.server)") }
            let token = try config.token()
            let newStore = try MeetingStore(saveDir: config.saveDirectory, name: name, prep: prep,
                                            sources: sources, client: "memoir-app", saveAudio: config.saveAudio,
                                            postprocess: pipeline == nil ? nil : self.choice)
            store = newStore
            self.store = newStore
            folder = newStore.folder
            var events: AsyncStream<SessionEvent>?
            for attempt in 1 ... Self.networkAttempts {
                // A session is single-use, so each attempt gets a fresh one.
                let session = MeetingSession(options: SessionOptions(
                    server: server, token: token, sources: sources, name: name, prep: prep, app: "memoir-app",
                    echoGate: config.echoGate))
                if newStore.saveAudio {
                    session.onAudio = { source, samples in try? newStore.record(audio: samples, from: source) }
                }
                self.session = session
                do {
                    events = try await session.start()
                    break
                } catch MemoirError.localNetworkBlocked(_) where attempt < Self.networkAttempts {
                    // The Local Network prompt may be up: connections fail until it's answered (INSTALL.md #6).
                    status = .waitingForNetwork
                    try? await Task.sleep(for: .seconds(2))
                    if status == .stopping {
                        newStore.discardIfEmpty()
                        finish(.idle)
                        return
                    }
                }
            }
            guard let events else { throw AppError("couldn't connect to \(config.server)") }
            startedAt = Date()
            for await event in events { handle(event) }
        } catch {
            store?.discardIfEmpty()
            finish(.failed(String(describing: error)))
        }
    }

    /// How many times to try connecting while macOS's Local Network prompt may be pending (~2 s apart).
    private static let networkAttempts = 10

    /// Starts the last call again (after a failure).
    func retry() async {
        await start(name: callName, prep: prep, source: source)
    }

    func stop() {
        guard status != .stopping else { return }
        if status == .waitingForNetwork {  // the retry loop notices and ends quietly
            status = .stopping
            return
        }
        guard let session else { return }
        status = .stopping
        session.stop()
    }

    /// The call in the overlay can be renamed: the live one, or the one just recorded (not while a step
    /// is working in its folder). Calls opened from Recent Calls can't be.
    var canRename: Bool { isRecording || (lastStore != nil && lastStore?.folder == folder && !isBusy(folder)) }

    /// Renames the call — during it, or after it.
    func rename(to name: String) {
        guard name != callName, canRename else { return }
        callName = name
        guard let store = store ?? lastStore else { return }
        let old = store.folder.path
        try? store.rename(to: name)
        folder = store.folder
        let new = store.folder.path
        if new != old {
            pipelineStates[new] = pipelineStates.removeValue(forKey: old)
            tooShort[new] = tooShort.removeValue(forKey: old)
            processingErrors[new] = processingErrors.removeValue(forKey: old)
        }
        if self.store != nil {
            let session = session
            Task { try? await session?.sendRename(to: name) }
        } else {
            refreshRecent()
        }
    }

    /// Adds a quick note, stamped at `t` (when typing began) or now.
    func addNote(_ text: String, at t: Double? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, let store else { return }
        let t = t ?? session.elapsed
        try? store.addQuickNote(at: t, text)
        quickNotes.append(QuickNote(t: t, text: text))
        Task { try? await session.sendNote(id: "n\(Int(t * 1000))", at: t, text: text) }
    }

    /// Adds prep during the call (someone joined, a doc was pasted), stamped like a note.
    func addPrep(_ text: String, at t: Double? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, let store else { return }
        let t = t ?? session.elapsed
        try? store.addPrep(at: t, text)
        prepAdditions.append(QuickNote(t: t, text: text))
        Task { try? await session.sendPrep(at: t, text: text) }
    }

    func showOverlay() {
        overlay.show(model: self)
        overlayVisible = true
    }

    func toggleOverlay() {
        if overlayVisible { overlay.hide() } else { overlay.show(model: self) }
        overlayVisible.toggle()
    }

    /// Opens Settings in front of every other app, on the screen the pointer is on, and keeps it above
    /// other windows while it's open (a menu-bar app's windows otherwise open behind the active app).
    func showSettings(_ openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        bringToFront(where: { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" || $0.title.hasSuffix("Settings") },
                     floating: true)
    }

    /// Everything about this build, for About, Settings and bug reports.
    var versionReport: String {
        let version = MemoirVersion.current
        var lines = ["Memoir \(version.display)"] + version.details
        lines.append("server: " + (serverVersion.map { "memoir-asr \($0)" } ?? "not connected yet")
                     + ", wire protocol \(Wire.protocolVersion)")
        return lines.joined(separator: "\n")
    }

    /// The standard About window — in front, on the pointer's screen, like Settings. A menu-bar app has
    /// no visible app menu, so this is the only way to it.
    func showAbout() {
        NSApp.activate()
        let version = MemoirVersion.current
        let credits = versionReport.split(separator: "\n").dropFirst().joined(separator: "\n")
            + "\n\ngithub.com/the-dsvolk/memoir"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Memoir",
            .applicationVersion: version.display,
            .version: version.isStamped ? "build \(version.build)" : "unstamped",
            .credits: NSAttributedString(string: credits, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]),
        ])
        bringToFront(where: { $0 is NSPanel && !($0 is OverlayPanel) && $0.isVisible }, floating: true)
    }

    /// Waits for the window to exist (SwiftUI makes it on first open), then floats it, moves it to the
    /// pointer's screen (if it's on another one) and the current Space, and brings it forward.
    private func bringToFront(where match: @escaping (NSWindow) -> Bool, floating: Bool, attempt: Int = 0) {
        guard let window = NSApp.windows.first(where: match) else {
            guard attempt < 20 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                bringToFront(where: match, floating: floating, attempt: attempt + 1)
            }
            return
        }
        if floating { window.level = .floating }
        window.collectionBehavior.insert(.moveToActiveSpace)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), window.screen != screen {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func open(_ url: URL?) {
        let target = url ?? config.saveDirectory
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        NSWorkspace.shared.open(target)
    }

    func quit() {
        if let job = activeJob {
            guard confirm("Processing “\(job.title)” isn't finished",
                          detail: "Quitting stops it. You can run it again later from Recent Calls.", button: "Quit")
            else { return }
            queue.removeAll()
            runner?.cancel()  // SIGTERM to the step now; it shows as interrupted next time
        }
        guard isRecording else { NSApp.terminate(nil); return }
        stop()
        Task {  // give the server a moment to flush the last words into the record
            for _ in 0 ..< 30 where isRecording { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.terminate(nil)
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .ready(let model, let chunkMs, let version):
            status = .live
            serverInfo = "\(model), \(chunkMs) ms"
            serverVersion = version ?? "before 0.3"
            UserDefaults.standard.set(serverVersion, forKey: "lastServerVersion")
            try? store?.setServer(model: model, chunkMs: chunkMs, version: version)
        case .capturing(let what):
            capturing = what.joined(separator: "; ")
        case .message(let msg):
            if msg.type == "final" { try? store?.record(final: msg) }
            transcript.apply(msg)
        case .silenceHint:
            silenceHint = true
        case .reconnecting(let reason):
            dropped = (elapsed, reason)
            if status != .stopping { status = .reconnecting(reason) }
        case .reconnected(let downtime):
            if let dropped { try? store?.addReconnect(at: dropped.t, reason: dropped.reason, downtime: downtime) }
            dropped = nil
            if case .reconnecting = status { status = .live }
        case .stopped(let serverPath, let latency):
            recordUnrecoveredDrop()
            if let gate = session?.echoGate?.stats { try? store?.setEchoGate(gate) }
            try? store?.finish(serverPath: serverPath)
            lastSummary = latency.summary
            let folder = store?.folder
            finish(.idle)
            if let folder { afterCall(folder) }
        case .failed(let message):
            recordUnrecoveredDrop()
            try? store?.finish(serverPath: nil)
            finish(.failed(message))
        }
    }

    private func recordUnrecoveredDrop() {
        if let dropped { try? store?.addReconnect(at: dropped.t, reason: dropped.reason, downtime: nil) }
        dropped = nil
    }

    private func finish(_ final: Status) {
        status = final
        session = nil
        if let store { lastStore = store }
        store = nil
        refreshRecent()
    }

    // MARK: - After the call (DESIGN.md §4.8)

    func loadPipeline() {
        do {
            pipeline = try PipelineConfig.load()
            pipelineError = nil
        } catch {
            pipeline = nil
            pipelineError = String(describing: error)
        }
    }

    /// Runs the steps chosen in New Call — unless the call was too short to be worth it.
    private func afterCall(_ folder: URL) {
        guard let pipeline, !choice.steps.isEmpty else { return }
        let finals = (try? CallInfo.load(folder))?.finals ?? 0
        guard finals >= pipeline.minFinals else {
            tooShort[folder.path] = finals
            return
        }
        process(folder, steps: choice.steps)
    }

    /// Steps the call was set up with (else the pipeline's defaults) — what "Run All" and Retry run.
    func chosenSteps(for folder: URL) -> [String] {
        let info = try? CallInfo.load(folder)
        if let steps = info?.postprocess?.steps, !steps.isEmpty { return steps }
        return pipeline?.defaultSteps(keepLocal: info?.postprocess?.keepLocal ?? false) ?? []
    }

    /// Runs `steps` on a call from the menus, checking first if remote steps would undo "Keep local only".
    func run(_ steps: [String], on folder: URL, force: Bool) {
        let info = try? CallInfo.load(folder)
        if info?.postprocess?.keepLocal == true, let pipeline {
            let remote = pipeline.selection(steps).compactMap(pipeline.step).filter(\.remote)
            if !remote.isEmpty, !confirm("“\(info?.title ?? folder.lastPathComponent)” is marked Keep local only",
                                         detail: "\(remote.map(\.label).joined(separator: " and ")) sends it off this Mac.",
                                         button: "Run Anyway") {
                return
            }
        }
        process(folder, steps: steps, force: force)
    }

    /// Queues a job; jobs run one at a time.
    func process(_ folder: URL, steps: [String], force: Bool = false) {
        guard !steps.isEmpty, !isBusy(folder) else { return }
        tooShort[folder.path] = nil
        processingErrors[folder.path] = nil
        let title = (try? CallInfo.load(folder))?.title ?? folder.lastPathComponent
        queue.append(PipelineJob(folder: folder, steps: steps, force: force, title: title))
        showCall(folder)  // so the progress is in view
        runNext()
    }

    /// Shows a recorded call in the overlay — its transcript and the after-the-call row — unless a call
    /// is live (the overlay belongs to it then).
    func showCall(_ folder: URL) {
        guard !isRecording else { return }
        if self.folder?.standardizedFileURL != folder.standardizedFileURL {
            let info = try? CallInfo.load(folder)
            self.folder = folder
            callName = info?.name ?? ""
            transcript = TranscriptModel.load(folder)
            quickNotes.removeAll()
            prepAdditions.removeAll()
            prep = ""
            silenceHint = false
            startedAt = nil
            status = .idle
            if pipelineStates[folder.path] == nil { pipelineStates[folder.path] = PipelineState.load(folder) }
        }
        if !overlayVisible { showOverlay() }
    }

    func cancelProcessing(_ folder: URL) {
        queue.removeAll { $0.folder == folder }
        if activeJob?.folder == folder { runner?.cancel() }
    }

    /// A job for this call is queued or running.
    func isBusy(_ folder: URL?) -> Bool {
        guard let folder else { return false }
        return activeJob?.folder == folder || queue.contains { $0.folder == folder }
    }

    /// The steps a queued or running job will run on `folder` (to show them before they start).
    func plannedSteps(_ folder: URL) -> [String] {
        guard let job = activeJob?.folder == folder ? activeJob : queue.first(where: { $0.folder == folder }) else { return [] }
        return pipeline?.selection(job.steps) ?? job.steps
    }

    private func runNext() {
        guard activeJob == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        activeJob = job
        loadPipeline()  // pick up edits to pipeline.toml
        let key = job.folder.path
        guard let pipeline else {
            processingErrors[key] = pipelineError ?? "no pipeline: add ~/.config/memoir/pipeline.toml (INSTALL.md)"
            activeJob = nil
            runNext()
            return
        }
        let runner = PipelineRunner(config: pipeline, call: job.folder)
        self.runner = runner
        Task {
            do {
                let state = try await runner.run(steps: job.steps, force: job.force) { state in
                    Task { @MainActor in self.show(state, for: key) }
                }
                show(state, for: key)
                notify(job, state, pipeline)
            } catch {
                processingErrors[key] = String(describing: error)
            }
            self.runner = nil
            activeJob = nil
            refreshRecent()
            runNext()
        }
    }

    /// Updates arrive on the main actor out of order at worst: keep the newest.
    private func show(_ state: PipelineState, for key: String) {
        if let current = pipelineStates[key]?.updatedAt, let new = state.updatedAt, new < current { return }
        pipelineStates[key] = state
    }

    private func notify(_ job: PipelineJob, _ state: PipelineState, _ pipeline: PipelineConfig) {
        let steps = pipeline.selection(job.steps).compactMap { id in pipeline.step(id).flatMap { s in state.steps[id].map { (s, $0) } } }
        if let (step, failed) = steps.first(where: { $0.1.status == .failed }) {
            Notifier.shared.post(title: "\(step.label) failed — \(job.title)", body: failed.message ?? "",
                                 open: PipelineState.log(job.folder, step: step.id))
        } else if steps.allSatisfy({ $0.1.status == .ok }) {
            let link = steps.last(where: { $0.1.url != nil }).flatMap { $0.1.url.flatMap(URL.init(string:)) }
            let file = steps.last(where: { !($0.1.outputs ?? []).isEmpty })
                .map { job.folder.appendingPathComponent($0.1.outputs![0]) }
            Notifier.shared.post(title: "“\(job.title)” is ready",
                                 body: steps.map(\.0.label).joined(separator: ", ") + (link != nil ? " — click to open" : ""),
                                 open: link ?? file)
        }
    }

    func refreshRecent() {
        recentCalls = CallInfo.recent(in: config.saveDirectory, limit: 8).map {
            RecentCall(info: $0, state: pipelineStates[$0.id] ?? PipelineState.load($0.folder))
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirm(_ message: String, detail: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
