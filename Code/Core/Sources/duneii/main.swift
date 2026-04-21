import Foundation
import AppKit
import DuneIICore
import DuneIIRendering
import Memoirs

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var gameWindow: GameWindow?

    func applicationDidFinishLaunching(_: Notification) {
        AppMenu.install()
        Self.setupLogging()
        guard let installDir = Installation.discover() else {
            presentFatal("""
Unable to locate the Dune II install.

Expected a directory matching \
'Repositories/patched_107_unofficial' in one of the current working \
directory's parent folders. Run `duneii` from within the project tree.
""")
            return
        }
        Log.info("duneii boot — install at \(installDir.path)")
        let installation: Installation
        let assets: AssetLoader
        do {
            installation = try Installation(rootDirectory: installDir)
            assets = try AssetLoader(installation: installation)
        } catch {
            Log.error("install open failed: \(error)")
            presentFatal("Failed to open install: \(error)")
            return
        }
        Log.info("install open: \(installation.pakURLs.count) PAKs indexed")
        let window = GameWindow(assets: assets)
        window.show()
        self.gameWindow = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Install the rotating file memoir in the repo's `Logs/` directory
    /// on every boot. Keeps the ten most recent run files so you can
    /// compare consecutive runs. Compile-time gated via `Log`'s
    /// `#if DEBUG` — release builds skip this entirely and the
    /// function body below compiles away.
    private static func setupLogging() {
        #if DEBUG
        let logsRoot = URL(fileURLWithPath:
            "/Users/alex/Programming/LonelyBytes/DuneIIRemake/Logs",
            isDirectory: true
        )
        do {
            let runURL = try LogRotator.prepareNewRunFile(
                logsRoot: logsRoot, keepLatest: 10
            )
            let fileMemoir = try FileMemoir(url: runURL)
            // Default to `.debug` so every useful domain event lands in
            // the log without the VM's per-opcode `FUNCTION` spam (which
            // is tagged `.verbose`). Set `DUNEII_LOG_VERBOSE=1` before
            // launch to widen the filter when debugging the VM itself.
            let minLevel: FilteringMemoir.Configuration.Level =
                (ProcessInfo.processInfo.environment["DUNEII_LOG_VERBOSE"] == "1")
                ? .verbose : .debug
            let filtered = FilteringMemoir(
                memoir: fileMemoir,
                defaultConfiguration: .init(minLevelShown: minLevel)
            )
            Log.setup(memoir: filtered)
            Log.info("log file: \(runURL.path) (level=\(minLevel))")
        } catch {
            // Fall back to stderr-less behaviour (VoidMemoir default).
            // Nothing we can do if the logs directory is inaccessible.
        }
        #endif
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "duneii"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
