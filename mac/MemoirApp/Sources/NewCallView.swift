import MemoirKit
import SwiftUI

/// "New Call…": name the call, choose what to listen to, add context notes, start (DESIGN.md §4.5, D13).
/// The notes editor fills the window, so resizing the window gives more room to write.
struct NewCallView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var name = ""
    @State private var context = ""
    @State private var source = "mic+system"

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
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.headline)
                TextEditor(text: $context)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .overlay(alignment: .topLeading) {
                        if context.isEmpty {
                            Text("Optional: attendees, agenda, links…")
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
            context = ""
            source = model.source
        }
    }

    private var folderPreview: String {
        let url = model.config.saveDirectory.appendingPathComponent(MeetingStore.folderName(date: Date(), name: name))
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func start() {
        dismissWindow(id: "new-call")
        let (name, context, source) = (name, context, source)
        Task { await model.start(name: name, context: context, source: source) }
    }
}
