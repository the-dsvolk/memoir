import AppKit
import MemoirKit
import SwiftUI

/// The always-on-top transcript panel (DESIGN.md §4.5): floats over full-screen calls, joins every
/// Space, never activates the app — but can take typing for the quick-note field.
final class OverlayPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                   styleMask: [.nonactivatingPanel, .borderless, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: rootView)
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
        }
    }

    override var canBecomeKey: Bool { true }  // the quick-note field needs key events
}

@MainActor
final class OverlayController {
    private var panel: OverlayPanel?

    func show(model: AppModel) {
        if panel == nil { panel = OverlayPanel(rootView: OverlayView(model: model)) }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct OverlayView: View {
    let model: AppModel
    @State private var note = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusPill(status: model.status)
                TextField("Untitled call", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { model.rename(to: name) }
                Spacer()
                if let startedAt = model.startedAt, model.isRecording {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(clock(context.date.timeIntervalSince(startedAt))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if model.isRecording {
                    Button("Stop") { model.stop() }.disabled(model.status == .stopping)
                } else {
                    Button { model.toggleOverlay() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }

            if model.silenceHint {
                Text("No system audio yet — if something is playing, allow Memoir under System Settings › Privacy & Security › Screen & System Audio Recording, then restart Memoir.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if case .failed(let message) = model.status {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.transcript.lines) { line in
                            TranscriptRow(line: line, labelled: model.sources.count > 1).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.transcript.lines.last?.text) {
                    if let last = model.transcript.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if model.isRecording {
                TextField("Quick note — Enter to add", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.addNote(note)
                        note = ""
                    }
            } else if !model.lastSummary.isEmpty, let folder = model.folder {
                HStack {
                    Text("Saved to \(folder.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Folder") { model.open(folder) }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { name = model.callName }
        .onChange(of: model.callName) { name = model.callName }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct TranscriptRow: View {
    let line: TranscriptModel.Line
    let labelled: Bool

    var body: some View {
        let text = Text(line.text).foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
        if labelled {
            Text("\(Text(label).bold().foregroundStyle(line.source == "me" ? Color.accentColor : Color.primary)) \(text)")
        } else {
            text
        }
    }

    private var label: String { line.source.prefix(1).uppercased() + line.source.dropFirst() + ":" }
}

/// The small coloured badge with the real connection state (DESIGN.md §4.5).
struct StatusPill: View {
    let status: AppModel.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var text: String {
        switch status {
        case .idle: "idle"
        case .connecting: "connecting…"
        case .live: "live"
        case .stopping: "saving…"
        case .failed: "error"
        }
    }

    private var color: Color {
        switch status {
        case .live: .green
        case .failed: .red
        case .connecting, .stopping: .orange
        case .idle: .gray
        }
    }
}
