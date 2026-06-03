import DuneIIAudio
import SwiftUI

/// The app's Settings window (⌘,). Audio toggles for now — more preferences can join later. Bindings write
/// straight through to `GameModel`, which applies them live to the audio sink / music director.
public struct SettingsView: View {
    @State
    var model: GameModel

    public init(model: GameModel) { _model = State(initialValue: model) }

    public var body: some View {
        TabView {
            Form {
                Toggle("Sound effects", isOn: Binding(get: { model.soundEnabled }, set: { model.soundEnabled = $0 }))
                Toggle("Music", isOn: Binding(get: { model.musicEnabled }, set: { model.musicEnabled = $0 }))
                Picker(
                    "Music engine",
                    selection: Binding(get: { model.musicBackend }, set: { model.musicBackend = $0 })
                ) {
                    ForEach(MusicBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .disabled(!model.musicEnabled)
            }
            .formStyle(.grouped)
            .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
        }
        .frame(width: 360, height: 200)
    }
}
