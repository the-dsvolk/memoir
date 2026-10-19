import SwiftUI

@main
struct MemoirApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : model.activeJob != nil ? "hourglass" : "waveform")
        }

        Window("New Call", id: "new-call") {
            NewCallView(model: model)
        }
        .windowResizability(.contentMinSize)  // resizable above the content's minimum; the notes editor grows
        .defaultSize(width: 620, height: 500)

        Settings {
            SettingsView(model: model)
        }
    }
}
