import MemoirKit
import SwiftUI

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRecording {
            Text("● \(model.callName.isEmpty ? "Untitled call" : model.callName)")
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(model.status == .stopping)
            Button(model.overlayVisible ? "Hide Transcript" : "Show Transcript") { model.toggleOverlay() }
            Button("Open Call Folder") { model.open(model.folder) }
        } else {
            Button("New Call…") {
                NSApp.activate()
                openWindow(id: "new-call")
            }
            .keyboardShortcut("n")
            if case .failed(let message) = model.status {
                Text("Last call failed: \(message.prefix(80))")
            }
            if model.folder != nil {
                Button("Open Last Call Folder") { model.open(model.folder) }
            }
        }
        Divider()
        Button("Open Save Folder") { model.open(nil) }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Memoir") { model.quit() }
            .keyboardShortcut("q")
    }
}
