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

    init(model: GameModel) { self.model = model }

    func openDefaults() { for kind in ToolKind.allCases { open(kind) } }

    func toggle(_ kind: ToolKind) { (panels[kind]?.isVisible == true) ? close(kind) : open(kind) }

    func open(_ kind: ToolKind) {
        if let panel = panels[kind] { panel.orderFront(nil); model.openTools.insert(kind); return }
        let size = kind.defaultSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = kind.title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content(for: kind))
        panel.center()
        cascade(panel, kind: kind)
        panels[kind] = panel
        panel.orderFront(nil)
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
