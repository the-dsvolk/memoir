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
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if model.isRecording || !model.quickNotes.isEmpty || !model.prepAdditions.isEmpty {
                    Divider()
                    SidePane(model: model)  // grows with the overlay, within limits
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 380, maxHeight: .infinity)
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

/// Right of the transcript: **Notes** (mine, during the call) and **Prep** (material for the call — the
/// New Call prep plus anything added now, e.g. someone joined or a doc was pasted). One multi-line editor
/// adds to the open tab; an entry is stamped with the meeting time when you start typing it. Prep added
/// during the call is append-only (DESIGN.md §4.7).
struct SidePane: View {
    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes", prep = "Prep"
        var id: Self { self }
    }

    let model: AppModel
    @State private var tab: Tab = .notes
    @State private var noteDraft = ""
    @State private var noteStart: Double?
    @State private var prepDraft = ""
    @State private var prepStart: Double?
    @FocusState private var editing: Bool
    @AppStorage(TextAppearance.fontKey) private var fontName = ""
    @AppStorage(TextAppearance.sizeKey) private var fontSize = TextAppearance.defaultSize

    private var font: Font { TextAppearance.font(fontName, size: fontSize) }
    private var entries: [AppModel.QuickNote] { tab == .notes ? model.quickNotes : model.prepAdditions }
    private var draft: String { tab == .notes ? noteDraft : prepDraft }
    private var started: Double? { tab == .notes ? noteStart : prepStart }
    private var beforeCall: String { model.prep.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if tab == .prep, !beforeCall.isEmpty {
                            entry(caption: "Before the call", text: beforeCall)
                        }
                        ForEach(entries) { item in
                            entry(caption: meetingClock(item.t), text: item.text).id(item.id)
                        }
                        if entries.isEmpty, tab == .notes || beforeCall.isEmpty {
                            Text(tab == .notes ? "No notes yet" : "No prep yet").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.count) {
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)

            if model.isRecording {
                TextEditor(text: tab == .notes ? $noteDraft : $prepDraft)
                    .font(font)
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 70, maxHeight: 110)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(tab == .notes ? "Type a note — ⌘↩ to add" : "Add prep: someone joined, a doc… — ⌘↩")
                                .font(font).foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: noteDraft) { old, new in
                        if old.isEmpty, !new.isEmpty { noteStart = model.elapsed }
                        if new.isEmpty { noteStart = nil }
                    }
                    .onChange(of: prepDraft) { old, new in
                        if old.isEmpty, !new.isEmpty { prepStart = model.elapsed }
                        if new.isEmpty { prepStart = nil }
                    }
                HStack {
                    if let started { Text("at \(meetingClock(started))").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button(tab == .notes ? "Add Note" : "Add Prep") { add() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .controlSize(.small)
                }
            }
        }
    }

    private func entry(caption: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text(text).font(font).textSelection(.enabled)
        }
    }

    private func add() {
        switch tab {
        case .notes:
            model.addNote(noteDraft, at: noteStart)
            noteDraft = ""
            noteStart = nil
        case .prep:
            model.addPrep(prepDraft, at: prepStart)
            prepDraft = ""
            prepStart = nil
        }
        editing = true
    }
}

struct TranscriptRow: View {
    let line: TranscriptModel.Line
    let labelled: Bool
    @AppStorage(TextAppearance.fontKey) private var fontName = ""
    @AppStorage(TextAppearance.sizeKey) private var fontSize = TextAppearance.defaultSize

    var body: some View {
        let text = Text(line.text).foregroundStyle(line.isFinal ? Color.primary : Color.secondary)
        Group {
            if labelled {
                Text("\(Text(label).bold().foregroundStyle(line.source == "me" ? Color.accentColor : Color.primary)) \(text)")
            } else {
                text
            }
        }
        .font(TextAppearance.font(fontName, size: fontSize))
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
