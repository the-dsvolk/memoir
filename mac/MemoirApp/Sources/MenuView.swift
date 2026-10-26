import MemoirKit
import SwiftUI

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isRecording {
            Text("● \(model.callName.isEmpty ? "Untitled call" : model.callName)")
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(model.status == .stopping)
            Button(model.overlayVisible ? "Hide Transcript" : "Show Transcript") { model.toggleOverlay() }
            Button("Open Call Folder") { model.open(model.folder) }
        } else {
            Button("New Call…") {
                NSApp.activate()
                openWindow(id: "new-call")
            }
            .keyboardShortcut("n")
            if case .failed(let message) = model.status {
                Text("Last call failed: \(message.prefix(80))")
            }
            if model.folder != nil {
                Button(model.overlayVisible ? "Hide Last Call" : "Show Last Call") { model.toggleOverlay() }
            }
        }
        if let job = model.activeJob {
            Divider()
            Text("Processing “\(job.title)”\(model.queue.isEmpty ? "" : " (+\(model.queue.count) waiting)")…")
            Button("Cancel Processing") { model.cancelProcessing(job.folder) }
        }
        Divider()
        Menu("Recent Calls") {
            if model.recentCalls.isEmpty { Text("No calls yet") }
            ForEach(model.recentCalls) { call in
                Menu("\(call.info.title) — \(call.info.day)") { RecentCallMenu(model: model, call: call) }
            }
        }
        Button("Open Save Folder") { model.open(nil) }
        Button("Settings…") { model.showSettings(openSettings) }
            .keyboardShortcut(",")
        Divider()
        Button("About Memoir") { model.showAbout() }
        Button("Quit Memoir") { model.quit() }
            .keyboardShortcut("q")
    }
}

/// One call under Recent Calls (DESIGN.md §4.8): where its pipeline stands, what it made, run steps again.
struct RecentCallMenu: View {
    let model: AppModel
    let call: AppModel.RecentCall

    private var folder: URL { call.info.folder }
    private var steps: [PipelineStep] { model.pipeline?.steps ?? [] }
    private var busy: Bool { model.isBusy(folder) }

    var body: some View {
        Text(status)
        Button("Show Call") { model.showCall(folder) }
            .disabled(model.isRecording)
        Button("Open Folder") { model.open(folder) }
        ForEach(steps) { step in
            if let s = call.state?.steps[step.id], s.status == .ok {
                if let link = s.url, let url = URL(string: link) {
                    Button("Open \(step.label)") { NSWorkspace.shared.open(url) }
                    Button("Copy \(step.label) Link") { model.copy(link) }
                } else if let output = s.outputs?.first {
                    Button("Open \(step.label)") { NSWorkspace.shared.open(folder.appendingPathComponent(output)) }
                }
            }
        }
        if !steps.isEmpty {
            Divider()
            Group {
                ForEach(steps) { step in
                    Button("Run \(step.label)") { model.run([step.id], on: folder, force: true) }
                }
                Button("Run All Again") { model.run(model.chosenSteps(for: folder), on: folder, force: true) }
            }
            .disabled(busy)
        }
    }

    /// `12 lines · Summary ✓ · Google Doc ✗`
    private var status: String {
        var parts = ["\(call.info.finals) line\(call.info.finals == 1 ? "" : "s")"]
        if busy { parts.append("processing…") }
        for step in steps {
            guard let s = call.state?.steps[step.id] else { continue }
            let mark = switch s.status {
            case .ok: "✓"
            case .failed: "✗"
            case .running, .pending: "…"
            case .skipped: "–"
            case .cancelled: "■"
            }
            parts.append("\(step.label) \(mark)")
        }
        if call.info.postprocess?.keepLocal == true { parts.append("keep local") }
        return parts.joined(separator: " · ")
    }
}
