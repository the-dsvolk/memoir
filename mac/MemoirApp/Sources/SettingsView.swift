import AppKit
import MemoirKit
import SwiftUI

/// Settings — stored in ~/.config/memoir/config.toml, shared with the CLI (DESIGN.md §4.7).
struct SettingsView: View {
    let model: AppModel
    @State private var config = MemoirConfig.load()
    @State private var saveError: String?
    @AppStorage(TextAppearance.fontKey) private var fontName = ""
    @AppStorage(TextAppearance.sizeKey) private var fontSize = TextAppearance.defaultSize

    var body: some View {
        Form {
            Section("Transcript and notes text") {
                Picker("Font", selection: $fontName) {
                    Text("System").tag("")
                    Text("System Monospaced").tag(TextAppearance.systemMono)
                    Divider()
                    ForEach(TextAppearance.families, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $fontSize, in: TextAppearance.sizes, step: 1)
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("\(Text("Them:").bold()) So the plan for next quarter is to ship the beta.")
                    .font(TextAppearance.font(fontName, size: fontSize))
                    .lineLimit(2)
            }
            Section("Calls") {
                LabeledContent("Save calls to") {
                    HStack {
                        Text(config.saveDir).truncationMode(.middle).lineLimit(1)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Save audio (one WAV per source, about 115 MB an hour each)", isOn: $config.saveAudio)
                TextField("Server", text: $config.server)
                LabeledContent("Token file") { Text(config.tokenFile).foregroundStyle(.secondary) }
                Text("Shared with the memoir command-line tool: ~/.config/memoir/config.toml")
                    .font(.caption).foregroundStyle(.secondary)
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("After the call") {
                LabeledContent("Pipeline") {
                    HStack {
                        Text(PipelineConfig.defaultPath).foregroundStyle(.secondary)
                        Button("Show in Finder") { revealPipeline() }
                        Button("Reload") { model.loadPipeline() }
                    }
                }
                if let pipeline = model.pipeline {
                    ForEach(pipeline.steps) { step in
                        LabeledContent(step.label) {
                            Text(describe(step)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                    }
                } else {
                    Text(model.pipelineError ?? "No pipeline yet — copy mac/pipeline.example.toml there (INSTALL.md)")
                        .font(.caption).foregroundStyle(model.pipelineError == nil ? Color.secondary : Color.red)
                }
                Text("Shared with `memoir process`. Steps run on this Mac through your login shell; their logs are in each call's pipeline folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { config = MemoirConfig.load() }
        .onChange(of: config) {
            do {
                try config.save()
                model.config = config
                saveError = nil
            } catch {
                saveError = "Couldn't save settings: \(error.localizedDescription)"
            }
        }
    }

    private func describe(_ step: PipelineStep) -> String {
        let flags = [step.remote ? "sends the call off this Mac" : "local", step.enabledByDefault ? "on by default" : "off by default"]
        return step.run.joined(separator: " ") + " — " + flags.joined(separator: ", ")
    }

    private func revealPipeline() {
        let url = URL(fileURLWithPath: MemoirConfig.expand(PipelineConfig.defaultPath))
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            model.open(url.deletingLastPathComponent())
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = config.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            config.saveDir = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
