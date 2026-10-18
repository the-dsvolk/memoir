import AppKit
import MemoirKit
import Observation

/// The app's state: one call at a time, run by `MeetingSession` and recorded by `MeetingStore` — the
/// same core the CLI uses (D13).
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, connecting, waitingForNetwork, live, stopping
        case failed(String)
    }

    struct QuickNote: Identifiable, Equatable {
        let id = UUID()
        let t: Double  // meeting clock, seconds
        let text: String
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
    var quickNotes: [QuickNote] = []

    /// The meeting clock (seconds since the server said ready), for note timestamps.
    var elapsed: Double { session?.elapsed ?? 0 }

    @ObservationIgnored private var session: MeetingSession?
    @ObservationIgnored private var store: MeetingStore?
    @ObservationIgnored private let overlay = OverlayController()

    var isRecording: Bool { [.connecting, .waitingForNetwork, .live, .stopping].contains(status) }

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
        quickNotes.removeAll()
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
            let newStore = try MeetingStore(saveDir: config.saveDirectory, name: name, context: context,
                                            sources: sources, client: "memoir-app", saveAudio: config.saveAudio)
            store = newStore
            self.store = newStore
            folder = newStore.folder
            var events: AsyncStream<SessionEvent>?
            for attempt in 1 ... Self.networkAttempts {
                // A session is single-use, so each attempt gets a fresh one.
                let session = MeetingSession(options: SessionOptions(
                    server: server, token: token, sources: sources, name: name, context: context, app: "memoir-app"))
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
        await start(name: callName, context: context, source: source)
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

    func rename(to name: String) {
        guard name != callName else { return }
        callName = name
        guard let store else { return }
        try? store.rename(to: name)
        folder = store.folder
        let session = session
        Task { try? await session?.sendMeta(title: name) }
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
