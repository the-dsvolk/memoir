import MemoirKit
import SwiftUI

/// "New Call…": name the call, choose what to listen to, write prep for it, start (DESIGN.md §4.5, §4.7).
/// The prep editor fills the window, so resizing the window gives more room to write.
struct NewCallView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var name = ""
    @State private var prep = ""
    @State private var source = "mic+system"
    @State private var steps: Set<String> = []  // after the call (DESIGN.md §4.8)
    @State private var keepLocal = false
    @AppStorage(TextAppearance.fontKey) private var fontName = ""
    @AppStorage(TextAppearance.sizeKey) private var fontSize = TextAppearance.defaultSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $name, prompt: Text("e.g. Weekly sync"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                GridRow {
                    Text("Listen to")
                    Picker("Listen to", selection: $source) {
                        Text("Microphone + this Mac's audio (calls)").tag("mic+system")
                        Text("Microphone only (in person)").tag("mic")
                        Text("This Mac's audio only").tag("system")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Saved to")
                    Text(folderPreview)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("After the call")
                    afterTheCall
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prep").font(.headline)
                TextEditor(text: $prep)
                    .font(TextAppearance.font(fontName, size: fontSize))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .overlay(alignment: .topLeading) {
                        if prep.isEmpty {
                            Text("Attendees, agenda, past notes, docs — anything useful for this call")
                                .font(TextAppearance.font(fontName, size: fontSize))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 140, maxHeight: .infinity)  // grows with the window
            }
            .frame(maxHeight: .infinity)

            HStack {
                if source != "system" {
                    Text("With the microphone and this Mac's audio, wear headphones so the mic doesn't hear the call too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismissWindow(id: "new-call") }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRecording)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620, maxWidth: .infinity, minHeight: 420, idealHeight: 500, maxHeight: .infinity)
        .onAppear {
            name = ""
            prep = ""
            source = model.source
            model.loadPipeline()
            steps = Set(model.pipeline?.defaultSteps() ?? [])
            keepLocal = false
        }
    }

    /// One checkbox per pipeline step, and "Keep local only" (DESIGN.md §4.8).
    @ViewBuilder private var afterTheCall: some View {
        if let pipeline = model.pipeline, !pipeline.steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    ForEach(pipeline.steps) { step in
                        Toggle(step.label, isOn: binding(step, in: pipeline))
                            .disabled(keepLocal && step.remote)
                    }
                    Toggle("Keep local only", isOn: $keepLocal)
                        .help("Nothing from this call leaves the Mac: steps that send it elsewhere are off")
                }
                Text(afterTheCallHint(pipeline))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let error = model.pipelineError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
        } else {
            Text("Nothing — steps go in ~/.config/memoir/pipeline.toml (INSTALL.md)")
                .foregroundStyle(.secondary)
        }
    }

    /// Ticking a step ticks what it needs; unticking one unticks what needs it.
    private func binding(_ step: PipelineStep, in pipeline: PipelineConfig) -> Binding<Bool> {
        Binding(
            get: { steps.contains(step.id) && !(keepLocal && step.remote) },
            set: { on in
                if on {
                    steps.formUnion(pipeline.selection([step.id]))
                } else {
                    steps.remove(step.id)
                    steps.subtract(pipeline.dependents(of: step.id))
                }
            })
    }

    private func afterTheCallHint(_ pipeline: PipelineConfig) -> String {
        let chosen = pipeline.selection(Array(steps), keepLocal: keepLocal).compactMap { pipeline.step($0) }
        if chosen.isEmpty { return keepLocal ? "Nothing leaves this Mac; nothing runs after the call." : "Nothing runs after the call." }
        let remote = chosen.contains(where: \.remote)
        return "When you stop: " + chosen.map(\.label).joined(separator: " → ")
            + (remote ? ". This sends the call off this Mac." : ", on this Mac.")
    }

    private var choice: PostprocessChoice {
        PostprocessChoice(steps: model.pipeline?.selection(Array(steps), keepLocal: keepLocal) ?? [], keepLocal: keepLocal)
    }

    private var folderPreview: String {
        let url = model.config.saveDirectory.appendingPathComponent(MeetingStore.folderName(date: Date(), name: name))
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func start() {
        dismissWindow(id: "new-call")
        let (name, prep, source, choice) = (name, prep, source, choice)
        Task { await model.start(name: name, prep: prep, source: source, choice: choice) }
    }
}
