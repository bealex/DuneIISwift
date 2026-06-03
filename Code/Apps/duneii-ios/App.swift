import DuneIIClient
import SwiftUI

/// Dune II — the iOS game client. Shares everything with the macOS app via `DuneIIClient` (the same
/// `GameModel`, `GameSidebar`, `GameScene`); only this shell and the SpriteKit host differ. The original
/// install's PAKs are bundled in the app under `GameData/` (the macOS app reads them from disk instead).
@main
struct DuneIIiOSApp: App {
    @State private var model = GameModel(assets: AssetStore(installURL: DuneIIiOSApp.gameDataURL))

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
