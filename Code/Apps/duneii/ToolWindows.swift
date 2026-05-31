import AppKit
import SwiftUI

/// The tool windows that float over the (possibly fullscreened) map window.
enum ToolKind: String, CaseIterable, Identifiable {
    case minimap, inspector, economy, debug
    var id: String { rawValue }
    var title: String {
        switch self {
            case .minimap:   return "Minimap"
            case .inspector: return "Selection"
            case .economy:   return "Economy"
            case .debug:     return "Debug"
        }
    }
    /// The toolbar toggle's SF Symbol.
    var symbol: String {
        switch self {
            case .minimap:   return "map"
            case .inspector: return "info.circle"
            case .economy:   return "dollarsign.circle"
            case .debug:     return "ladybug"
        }
    }
    var defaultSize: CGSize {
        switch self {
            case .minimap:   return CGSize(width: 240, height: 260)
            case .inspector: return CGSize(width: 260, height: 360)
            case .economy:   return CGSize(width: 240, height: 320)
            case .debug:     return CGSize(width: 280, height: 240)
        }
    }
}

/// Creates and tracks the tool windows as floating AppKit `NSPanel`s (so they stay visible **over** the
/// fullscreened map via `.fullScreenAuxiliary`), each hosting its SwiftUI panel. The map window's toolbar
/// toggles them; closing one via its title-bar button updates `model.openTools` so the toggle un-highlights.
@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    private let model: GameModel
    private var panels: [ToolKind: NSPanel] = [:]
    /// The main map window — the tool panels are added as **child windows** of it (so they sit above it
    /// always, yet drop behind other applications when ours is inactive, rather than floating system-wide).
    private weak var mainWindow: NSWindow?

    init(model: GameModel) { self.model = model }

    func openDefaults() { for kind in ToolKind.allCases { open(kind) } }

    /// Adopt the main window once SwiftUI has created it: remember it (for its own frame autosave) and
    /// re-parent any already-open tool panels onto it as child windows. Idempotent — the `WindowAccessor`
    /// may call it repeatedly with the same window.
    func attachToMain(_ window: NSWindow) {
        if window.frameAutosaveName != "DuneII.main" {
            window.setFrameUsingName("DuneII.main")
            window.setFrameAutosaveName("DuneII.main")
        }
        guard mainWindow !== window else { return }
        mainWindow = window
        for panel in panels.values where panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
    }

    func toggle(_ kind: ToolKind) { (panels[kind]?.isVisible == true) ? close(kind) : open(kind) }

    func open(_ kind: ToolKind) {
        if let panel = panels[kind] {
            if let mainWindow, panel.parent !== mainWindow { mainWindow.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil); model.openTools.insert(kind); return
        }
        let size = kind.defaultSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = kind.title
        // Normal level + parented to the map window (below): above the map, below other apps. Stays visible
        // when the map is fullscreened via `.fullScreenAuxiliary`.
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content(for: kind))
        // Restore the saved frame; only place it (centre + cascade) the first time it's ever opened.
        let autosaveName = "DuneII.tool.\(kind.rawValue)"
        if !panel.setFrameUsingName(autosaveName) { panel.setContentSize(size); panel.center(); cascade(panel, kind: kind) }
        panel.setFrameAutosaveName(autosaveName)
        panels[kind] = panel
        if let mainWindow { mainWindow.addChildWindow(panel, ordered: .above) } else { panel.orderFront(nil) }
        model.openTools.insert(kind)
    }

    func close(_ kind: ToolKind) {
        panels[kind]?.close()
        model.openTools.remove(kind)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = panels.first(where: { $0.value === window })?.key else { return }
        model.openTools.remove(kind)
    }

    @ViewBuilder private func content(for kind: ToolKind) -> some View {
        switch kind {
            case .minimap:   MinimapView(model: model)
            case .inspector: InspectorPanel(model: model)
            case .economy:   EconomyPanel(model: model)
            case .debug:     DebugPanel(model: model)
        }
    }

    /// Tuck the panels into the screen's top-right so they don't all stack on the centre.
    private func cascade(_ panel: NSPanel, kind: ToolKind) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let index = CGFloat(ToolKind.allCases.firstIndex(of: kind) ?? 0)
        let x = screen.maxX - panel.frame.width - 20
        let y = screen.maxY - panel.frame.height - 20 - index * 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
