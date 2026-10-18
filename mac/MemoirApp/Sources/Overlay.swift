import AppKit
import MemoirKit
import SwiftUI

/// The always-on-top transcript panel (DESIGN.md §4.5): floats over full-screen calls, joins every
/// Space, never activates the app — but can take typing for the quick-note field.
final class OverlayPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 300),
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
            if model.status == .waitingForNetwork {
                Text("Waiting for network access — if macOS asks, allow Memoir to find devices on your local network (System Settings › Privacy & Security › Local Network).")
                    .font(.caption).foregroundStyle(.orange)
            }
            if case .failed(let message) = model.status {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(4)
                    Spacer()
                    Button("Retry") { Task { await model.retry() } }.controlSize(.small)
                }
            }

            HStack(alignment: .top, spacing: 12) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.isRecording || !model.quickNotes.isEmpty {
                    Divider()
                    NotesPane(model: model).frame(width: 260)
                }
            }

            if !model.isRecording, !model.lastSummary.isEmpty, let folder = model.folder {
                HStack {
                    Text("Saved to \(folder.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Folder") { model.open(folder) }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { name = model.callName }
        .onChange(of: model.callName) { name = model.callName }
    }

    private func clock(_ seconds: TimeInterval) -> String { meetingClock(seconds) }
}

func meetingClock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

/// Notes on the right of the transcript: the notes added so far, and a multi-line editor. A note is
/// stamped with the meeting time when you start typing it (you write after hearing the point).
struct NotesPane: View {
    let model: AppModel
    @State private var draft = ""
    @State private var startedAt: Double?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.quickNotes) { note in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meetingClock(note.t)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Text(note.text).font(.callout).textSelection(.enabled)
                            }
                            .id(note.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.quickNotes.count) {
                    if let last = model.quickNotes.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)

            if model.isRecording {
                TextEditor(text: $draft)
                    .font(.callout)
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 70, maxHeight: 110)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Type a note — ⌘↩ to add").font(.callout).foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: draft) { old, new in
                        if old.isEmpty, !new.isEmpty { startedAt = model.elapsed }
                        if new.isEmpty { startedAt = nil }
                    }
                HStack {
                    if let startedAt { Text("at \(meetingClock(startedAt))").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Add Note") { add() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .controlSize(.small)
                }
            }
        }
    }

    private func add() {
        model.addNote(draft, at: startedAt)
        draft = ""
        startedAt = nil
        editing = true
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
        case .waitingForNetwork: "waiting for network…"
        case .live: "live"
        case .stopping: "saving…"
        case .failed: "error"
        }
    }

    private var color: Color {
        switch status {
        case .live: .green
        case .failed: .red
        case .connecting, .waitingForNetwork, .stopping: .orange
        case .idle: .gray
        }
    }
}
