import AppKit
import DuneIIClient

/// Adopts the SwiftUI main window for frame autosave. (Earlier this also managed floating `NSPanel` tool
/// windows for the minimap/inspector/economy/debug; those folded into the in-window `GameSidebar`, so all
/// that remains is remembering the window so its frame is saved/restored across launches.)
@MainActor
final class ToolWindowManager: NSObject {
    private weak var mainWindow: NSWindow?

    init(model: GameModel) { super.init() }

    /// Called once SwiftUI has created the main window: give it a stable frame-autosave name so its size and
    /// position persist. Idempotent — `WindowAccessor` may call it repeatedly with the same window.
    func attachToMain(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        if window.frameAutosaveName != "DuneII.main" {
            window.setFrameUsingName("DuneII.main")
            window.setFrameAutosaveName("DuneII.main")
        }
    }
}
