import Foundation
import SpriteKit

/// Callback target that each scene uses to notify the host when it's done
/// (e.g. user clicked to advance). Implemented by `GameController`.
@MainActor
public protocol SceneCoordinator: AnyObject {
    /// The given scene signals it's finished and the host should move on.
    /// The coordinator decides what "next" means (MainMenu → Mentat →
    /// Scenario → …).
    func advance(from scene: SKScene)

    /// Explicit route request (e.g. menu button → scenario selector).
    func route(to route: Route)
}

/// Named destinations the host can jump to.
public enum Route: Sendable, Equatable {
    case intro
    case mainMenu
    /// Pre-scenario Mentat briefing. Carries the target scenario so
    /// the coordinator knows where to route after the briefing clicks
    /// through. Player house + briefing WSA are derived from the
    /// scenario at scene-build time.
    case mentat(scenarioName: String)
    case scenario(name: String)
}
