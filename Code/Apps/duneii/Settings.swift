import SwiftUI

/// The app's Settings window (⌘,). Audio toggles for now — more preferences can join later. Bindings write
/// straight through to `GameModel`, which applies them live to the audio sink / music director.
struct SettingsView: View {
    @State var model: GameModel

    var body: some View {
        TabView {
            Form {
                Toggle("Sound effects", isOn: Binding(get: { model.soundEnabled }, set: { model.soundEnabled = $0 }))
                Toggle("Music", isOn: Binding(get: { model.musicEnabled }, set: { model.musicEnabled = $0 }))
            }
            .formStyle(.grouped)
            .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
        }
        .frame(width: 360, height: 180)
    }
}
