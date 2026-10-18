import SwiftUI

@main
struct MemoirApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
        }

        Window("New Call", id: "new-call") {
            NewCallView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }
    }
}
