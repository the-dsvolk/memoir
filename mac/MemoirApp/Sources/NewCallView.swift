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
        }
    }

    private var folderPreview: String {
        let url = model.config.saveDirectory.appendingPathComponent(MeetingStore.folderName(date: Date(), name: name))
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func start() {
        dismissWindow(id: "new-call")
        let (name, prep, source) = (name, prep, source)
        Task { await model.start(name: name, prep: prep, source: source) }
    }
}
