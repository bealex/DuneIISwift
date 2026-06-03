import AppKit
import SwiftUI

/// Dune II behavioural scenario lab (macOS). Generates an 8×8 sand/rock terrain, places two chosen unit
/// types into one of the predefined scenarios, runs it, and renders the result with a 1×–16× zoom — so
/// each per-unit behaviour can be assessed visually as it's ported. Run from `Code/`:
/// `swift run scenariolab [installDir]`.
@main
struct ScenarioLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate
    @State
    private var model = ScenarioLabModel(assets: ScenarioAssets(installURL: ScenarioLabApp.installURL()))

    var body: some Scene {
        WindowGroup("Dune II — Scenario Lab") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 520)
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
