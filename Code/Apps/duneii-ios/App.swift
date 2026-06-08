import AVFoundation
import DuneIIClient
import SwiftUI

/// Dune II — the iOS game client. Shares everything with the macOS app via `DuneIIClient` (the same
/// `GameModel`, `GameSidebar`, `GameScene`); only this shell and the SpriteKit host differ. The original
/// install's PAKs are bundled in the app under `GameData/` (the macOS app reads them from disk instead); the
/// music (`*.ADL`) is bundled under `Audio/Music/`.
@main
struct DuneIIiOSApp: App {
    @State
    private var model: GameModel

    init() {
        // iOS only routes `AVAudioEngine` output through an **active audio session** — without this there's no
        // music or sound effects at all. `.playback` plays even with the ring/silent switch on. Configure it
        // before `GameModel` builds its audio engines (below).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        _model = State(initialValue: GameModel(assets: AssetStore(installURL: DuneIIiOSApp.gameDataURL), audioEnabled: true))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)  // hide the home indicator for the full-screen map
        }
    }

    /// The bundled original assets (`*.PAK`), copied into `GameData/` of the app resources at build time.
    static var gameDataURL: URL {
        Bundle.main.resourceURL?.appending(path: "GameData") ?? Bundle.main.bundleURL
    }
}
