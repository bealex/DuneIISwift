import AppKit
import SwiftUI

/// Dune II — the native macOS game client (non-Catalyst). A SwiftUI main map window + floating AppKit tool
/// windows (minimap, selection, economy, debug). Run from `Code/`:
///   `swift run duneii [installDir]`  (installDir defaults to the bundled install).
@main
struct DuneIIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = GameModel(assets: AssetStore(installURL: DuneIIApp.installURL()))

    var body: some Scene {
        WindowGroup("Dune II") {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 600)
        }
        .commands {
            // Save / Load in the File menu (⌘S / ⌘O), alongside the toolbar buttons.
            CommandGroup(replacing: .saveItem) {
                Button("Save Game…") { presentSaveGame(model) }
                    .keyboardShortcut("s")
                    .disabled(model.simulation == nil)
                Button("Load Game…") { presentLoadGame(model) }
                    .keyboardShortcut("o")
            }
        }

        Settings { SettingsView(model: model) }
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
