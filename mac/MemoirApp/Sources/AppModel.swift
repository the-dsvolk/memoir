import AppKit
import MemoirKit
import Observation

/// The app's state: one call at a time, run by `MeetingSession` and recorded by `MeetingStore` — the
/// same core the CLI uses (D13).
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, connecting, live, stopping
        case failed(String)
    }

    var status: Status = .idle
    var config = MemoirConfig.load()
    var transcript = TranscriptModel()
    var callName = ""
    var context = ""
    var source = UserDefaults.standard.string(forKey: "source") ?? "mic+system"
    var folder: URL?
    var startedAt: Date?
    var serverInfo = ""
    var capturing = ""
    var silenceHint = false
    var lastSummary = ""
    var overlayVisible = false

    @ObservationIgnored private var session: MeetingSession?
    @ObservationIgnored private var store: MeetingStore?
    @ObservationIgnored private let overlay = OverlayController()

    var isRecording: Bool { [.connecting, .live, .stopping].contains(status) }

    var sources: [Source] {
        switch source {
        case "mic": [.me]
        case "system": [.them]
        default: [.me, .them]
        }
    }

    func start(name: String, context: String, source: String) async {
        guard !isRecording else { return }
        self.source = source
        UserDefaults.standard.set(source, forKey: "source")
        callName = name
        self.context = context
        transcript.clear()
        silenceHint = false
        lastSummary = ""
        startedAt = nil
        status = .connecting
        config = MemoirConfig.load()
        showOverlay()

        var store: MeetingStore?
        do {
            guard let server = URL(string: config.server) else { throw AppError("bad server URL \(config.server)") }
            let newStore = try MeetingStore(saveDir: config.saveDirectory, name: name, context: context,
                                            sources: sources, client: "memoir-app", saveAudio: config.saveAudio)
            store = newStore
            let session = MeetingSession(options: SessionOptions(
                server: server, token: try config.token(), sources: sources, name: name, context: context,
                app: "memoir-app"))
            if newStore.saveAudio {
                session.onAudio = { source, samples in try? newStore.record(audio: samples, from: source) }
            }
            self.store = newStore
            self.session = session
            folder = newStore.folder
            let events = try await session.start()
            startedAt = Date()
            for await event in events { handle(event) }
        } catch {
            store?.discardIfEmpty()
            finish(.failed(String(describing: error)))
        }
    }

    func stop() {
        guard let session, status != .stopping else { return }
        status = .stopping
        session.stop()
    }

    func rename(to name: String) {
        guard name != callName else { return }
        callName = name
        guard let store else { return }
        try? store.rename(to: name)
        folder = store.folder
        let session = session
        Task { try? await session?.sendMeta(title: name) }
    }

    func addNote(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, let store else { return }
        let t = session.elapsed
        try? store.addQuickNote(at: t, text)
        Task { try? await session.sendNote(id: "n\(Int(t * 1000))", at: t, text: text) }
    }

    func showOverlay() {
        overlay.show(model: self)
        overlayVisible = true
    }

    func toggleOverlay() {
        if overlayVisible { overlay.hide() } else { overlay.show(model: self) }
        overlayVisible.toggle()
    }

    func open(_ url: URL?) {
        let target = url ?? config.saveDirectory
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        NSWorkspace.shared.open(target)
    }

    func quit() {
        guard isRecording else { NSApp.terminate(nil); return }
        stop()
        Task {  // give the server a moment to flush the last words into the record
            for _ in 0 ..< 30 where isRecording { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.terminate(nil)
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .ready(let model, let chunkMs):
            status = .live
            serverInfo = "\(model), \(chunkMs) ms"
            try? store?.setServer(model: model, chunkMs: chunkMs)
        case .capturing(let what):
            capturing = what.joined(separator: "; ")
        case .message(let msg):
            if msg.type == "final" { try? store?.record(final: msg) }
            transcript.apply(msg)
        case .silenceHint:
            silenceHint = true
        case .stopped(let serverPath, let latency):
            try? store?.finish(serverPath: serverPath)
            lastSummary = latency.summary
            finish(.idle)
        case .failed(let message):
            try? store?.finish(serverPath: nil)
            finish(.failed(message))
        }
    }

    private func finish(_ final: Status) {
        status = final
        session = nil
        store = nil
    }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
