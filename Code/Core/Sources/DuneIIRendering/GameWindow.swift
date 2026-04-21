import Foundation
import AppKit
import SpriteKit

/// Minimal AppKit host window. Owns a single `SKView` scaled to the
/// original Dune II 320×200 aspect ratio with integer nearest-neighbour
/// sampling. The window is aspect-locked via `contentAspectRatio`, and
/// fullscreen-capable via the standard `.fullScreenPrimary` collection
/// behaviour — the titlebar's green button toggles fullscreen and
/// `⌃⌘F` works once the menu is installed.
@MainActor
public final class GameWindow {
    /// Native Dune II resolution. All window sizing is a multiple of this
    /// ratio (4× default = 1280×800).
    public static let nativeSize = NSSize(width: 320, height: 200)
    public static let defaultScale: CGFloat = 4.0
    public static let minScale: CGFloat = 2.0

    public static var defaultSize: NSSize {
        NSSize(width: nativeSize.width * defaultScale, height: nativeSize.height * defaultScale)
    }
    public static var minSize: NSSize {
        NSSize(width: nativeSize.width * minScale, height: nativeSize.height * minScale)
    }

    public let window: NSWindow
    public let controller: GameController

    public init(assets: AssetLoader, title: String = "Dune II Remake") {
        let content = NSRect(origin: .zero, size: Self.defaultSize)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let w = NSWindow(contentRect: content, styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.center()
        w.isReleasedWhenClosed = false

        // Lock resize to the 320:200 aspect. macOS enforces this on drag,
        // on zoom (green-button → maximise), and on programmatic setFrame.
        // Fullscreen bypasses the constraint — SpriteKit's aspectFit
        // letterboxes the scene inside the full-screen SKView.
        w.contentAspectRatio = Self.nativeSize
        w.contentMinSize = Self.minSize
        w.collectionBehavior.insert(.fullScreenPrimary)

        let skView = SKView(frame: content)
        skView.autoresizingMask = [.width, .height]
        skView.preferredFramesPerSecond = 60
        w.contentView = skView

        self.window = w
        self.controller = GameController(assets: assets, skView: skView)
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    /// Toggles the macOS fullscreen transition. Bound to `⌃⌘F` by the
    /// standard menu wiring in `AppMenu.install()`.
    @objc public func toggleFullScreen(_ sender: Any?) {
        window.toggleFullScreen(sender)
    }
}
