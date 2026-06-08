import DuneIIAudio
import SwiftUI

/// The app's Settings window (⌘,). Audio toggles for now — more preferences can join later. Bindings write
/// straight through to `GameModel`, which applies them live to the audio sink / music director.
public struct SettingsView: View {
    var model: GameModel

    public init(model: GameModel) { self.model = model }

    public var body: some View {
        TabView {
            Form { AudioSettingsRows(model: model) }
                .formStyle(.grouped)
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
        }
        .frame(width: 360, height: 200)
    }
}

/// The audio preference rows (sound / music / music engine) **without** a `Form`/`TabView` wrapper, so they
/// can sit in the macOS Settings window *and* be embedded as a section of the in-game Options form (iOS has
/// no ⌘, Settings scene, so this is the only place those toggles live there).
struct AudioSettingsRows: View {
    @Bindable
    var model: GameModel

    var body: some View {
        Group {
            Toggle("Sound effects", isOn: $model.soundEnabled)
            Toggle("Music", isOn: $model.musicEnabled)
            Picker("Music engine", selection: $model.musicBackend) {
                ForEach(MusicBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .disabled(!model.musicEnabled)
        }
    }
}
