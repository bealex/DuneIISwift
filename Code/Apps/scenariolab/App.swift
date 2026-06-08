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
    private var model: ScenarioLabModel?

    var body: some Scene {
        WindowGroup("Dune II — Scenario Lab") {
            Group {
                if let model {
                    ContentView(model: model)
                } else {
                    ProgressView("Loading assets…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 640, minHeight: 520)
            // Defer the asset-decoding model init past first paint (see the map viewer for why a `@State`
            // default value stalls launch).
            .task {
                if model == nil { model = ScenarioLabModel(assets: ScenarioAssets(installURL: Self.installURL())) }
            }
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
