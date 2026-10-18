import AppKit
import MemoirKit
import SwiftUI

/// Settings — stored in ~/.config/memoir/config.toml, shared with the CLI (DESIGN.md §4.7).
struct SettingsView: View {
    let model: AppModel
    @State private var config = MemoirConfig.load()
    @State private var saveError: String?

    var body: some View {
        Form {
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
