import MemoirKit
import SwiftUI

/// "New Call…": name the call, choose what to listen to, add context notes, start (DESIGN.md §4.5, D13).
struct NewCallView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var name = ""
    @State private var context = ""
    @State private var source = "mic+system"

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("e.g. Weekly sync"))
            Picker("Listen to", selection: $source) {
                Text("Microphone + this Mac's audio (calls)").tag("mic+system")
                Text("Microphone only (in person)").tag("mic")
                Text("This Mac's audio only").tag("system")
            }
            LabeledContent("Notes") {
                TextEditor(text: $context)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if context.isEmpty {
                            Text("Optional: attendees, agenda, links…")
                                .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            }
            LabeledContent("Saved to") {
                Text(folderPreview).font(.caption).foregroundStyle(.secondary).truncationMode(.middle).lineLimit(1)
            }
            if source != "system" {
                Text("With “Microphone + this Mac's audio”, wear headphones so the mic doesn't hear the call too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { dismissWindow(id: "new-call") }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRecording)
            }
            .padding()
        }
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
