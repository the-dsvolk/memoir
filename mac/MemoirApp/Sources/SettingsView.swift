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
    @AppStorage(TextAppearance.backgroundKey) private var background = TextAppearance.defaultBackground
    @AppStorage(TextAppearance.customColorKey) private var customColor = TextAppearance.defaultCustomColor
    @AppStorage(TextAppearance.opacityKey) private var opacity = TextAppearance.defaultOpacity

    var body: some View {
        Form {
            Section("Transcript window") {
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
                Picker("Background", selection: $background) {
                    ForEach(TextAppearance.backgrounds, id: \.tag) { Text($0.name).tag($0.tag) }
                }
                if background == "custom" {
                    ColorPicker("Colour", selection: customColorBinding, supportsOpacity: false)
                }
                if background != "material" {
                    LabeledContent("Opacity") {
                        HStack {
                            Slider(value: $opacity, in: 0.5 ... 1)
                            Text("\(Int((opacity * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {  // preview: text as the overlay shows it
                    Text("\(Text("Them:").bold()) So the plan for next quarter is to ship the beta.")
                    Text("\(Text("Me:").bold().foregroundStyle(Color.accentColor)) And the budget?")
                    Text("…still talking").foregroundStyle(.secondary)
                }
                .font(TextAppearance.font(fontName, size: fontSize))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .overlayBackground(setsWindowAppearance: false)
            }
            Section("Calls") {
                LabeledContent("Save calls to") {
                    HStack {
                        Text(config.saveDir).truncationMode(.middle).lineLimit(1)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Save audio (one WAV per source, about 115 MB an hour each)", isOn: $config.saveAudio)
                Toggle(isOn: $config.echoGate) {
                    Text("Silence the mic while it only hears the call")
                    Text("With the microphone and this Mac's audio, the call leaking from your headphones into the mic would show up as Me. Uses what the Mac plays to tell the leak from your voice.")
                }
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
                    if !pipeline.steps.isEmpty {
                        LabeledContent("Runs") { Text(pipeline.steps.map(\.label).joined(separator: " → ")) }
                    }
                    ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                        PipelineStepRow(number: index + 1, step: step, pipeline: pipeline)
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

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: TextAppearance.color(hex: customColor) ?? .black) },
            set: { customColor = TextAppearance.hex(NSColor($0)) })
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

/// One pipeline step in Settings: its number and name, what it runs after, what it does, whether it
/// sends the call off the Mac and is ticked by default — and the exact command, folded away.
struct PipelineStepRow: View {
    let number: Int
    let step: PipelineStep
    let pipeline: PipelineConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
                Text(step.label).font(.headline)
                if !step.needs.isEmpty {
                    Text("after \(step.needs.compactMap { pipeline.step($0)?.label }.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: step.remote ? "Remote" : "Local", color: step.remote ? .orange : .green)
                    .help(step.remote ? "Sends the call off this Mac — off for Keep local only calls" : "Stays on this Mac")
                Badge(text: step.enabledByDefault ? "On by default" : "Off by default", color: .secondary)
                    .help("Whether it's ticked in New Call")
            }
            Text(step.description ?? "No description — add description = \"…\" to this step in pipeline.toml")
                .font(.callout)
                .foregroundStyle(step.description == nil ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Command") {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// The command as run: the folder, Keychain variables (names only), argv, timeout.
    private var command: String {
        var lines: [String] = []
        if let cwd = step.cwd { lines.append("cd \(cwd)") }
        for (key, service) in step.keychain.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key) from the Keychain (\(service))")
        }
        for (key, value) in step.env.sorted(by: { $0.key < $1.key }) { lines.append("\(key)=\(value)") }
        lines.append(step.run.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        lines.append("timeout \(durationText(step.timeout))")
        return lines.joined(separator: "\n")
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}
