import AppKit
import SwiftUI

/// Native macOS asset inspector for the Dune II decoders + renderer. Run from `Code/`:
///   swift run rendertest [installDir]
/// `installDir` defaults to `../Repositories/patched_107_unofficial` (relative to the package).
@main
struct RenderTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate
    @State
    private var library = AssetLibrary(installURL: RenderTestApp.installURL())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .frame(minWidth: 960, minHeight: 640)
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
