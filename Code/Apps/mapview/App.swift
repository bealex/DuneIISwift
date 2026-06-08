import AppKit
import SwiftUI

/// Dune II scenario map viewer (macOS). Loads a scenario `.INI` into a `GameState` (generating the
/// landscape from its seed) and draws the terrain, structures, and units with SpriteKit. Run from
/// `Code/`:  `swift run mapview [installDir]`  (installDir defaults to the bundled install).
@main
struct MapViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate
    @State
    private var model: MapModel?

    var body: some Scene {
        WindowGroup("Dune II — Map Viewer") {
            Group {
                if let model {
                    ContentView(model: model)
                } else {
                    ProgressView("Loading assets…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            // Build the model — which decodes the install's PAKs and loads the first scenario — only after the
            // window first paints. Apple's Observation guidance warns against this kind of heavy work in a
            // `@State` default value, which runs synchronously before the first frame and stalls launch.
            .task { if model == nil { model = MapModel(assets: AssetStore(installURL: Self.installURL())) } }
        }
    }

    private static func installURL() -> URL {
        let arguments = CommandLine.arguments
        if arguments.count > 1 { return URL(fileURLWithPath: arguments[1]) }
        return URL(fileURLWithPath: "../Repositories/patched_107_unofficial")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool { true }
}
