import Foundation
import AppKit
import SpriteKit

/// Owns the `SKView`, the shared `AssetLoader`, and the scene graph. One
/// `GameController` exists per window. The app bootstrap instantiates it,
/// hands it a view, and calls `start()`.
@MainActor
public final class GameController: NSObject, SceneCoordinator {
    public let skView: SKView
    private let assets: AssetLoader
    public let jukebox: Jukebox
    public let voice: Voice?
    /// Scenario names to try in order. First hit wins. The install usually
    /// carries ~22 `SCENA001..022.INI`; pick mission 1 by default.
    private let defaultScenarios = ["SCENA001.INI", "SCENA002.INI"]
    /// Whether to start with `INTRO.WSA`. When the asset is missing we
    /// skip straight to the main menu.
    public let playIntroOnBoot: Bool

    public init(assets: AssetLoader, skView: SKView, playIntroOnBoot: Bool = true) {
        self.assets = assets
        self.skView = skView
        self.jukebox = Jukebox(loader: assets)
        self.voice = try? Voice(loader: assets)
        self.playIntroOnBoot = playIntroOnBoot
        super.init()
        skView.ignoresSiblingOrder = true
        skView.showsFPS = false
        skView.showsNodeCount = false
    }

    public func start() {
        if playIntroOnBoot, assets.installation.body(of: "INTRO.WSA") != nil {
            route(to: .intro)
        } else {
            routeToDefaultScenarioViaMentat()
        }
    }

    // MARK: SceneCoordinator

    public func advance(from scene: SKScene) {
        // Boot flow: Intro → Mentat(scenario) → Scenario. MainMenu is
        // still out of the chain until P7 campaign glue lands; today
        // the coordinator jumps straight to the default scenario's
        // briefing. A click in the Mentat screen advances to that
        // scenario's map.
        switch scene {
        case is IntroScene: routeToDefaultScenarioViaMentat()
        case is MainMenuScene: routeToDefaultScenarioViaMentat()
        case let mentat as MentatScene:
            route(to: .scenario(name: mentat.scenarioName))
        default: routeToDefaultScenarioViaMentat()
        }
    }

    private func routeToDefaultScenarioViaMentat() {
        guard let scenario = defaultScenarios.first(where: {
            assets.installation.body(of: $0) != nil
        }) else {
            route(to: .mainMenu)
            return
        }
        route(to: .mentat(scenarioName: scenario))
    }

    public func route(to route: Route) {
        switch route {
        case .intro:
            present(IntroScene(assets: assets))
        case .mainMenu:
            // Start background music on first main-menu entry. `play`
            // is a no-op on subsequent entries because AVMIDIPlayer
            // replaces the current song.
            _ = try? jukebox.play(named: "DUNE0.XMI")
            present(MainMenuScene(assets: assets))
        case .mentat(let scenarioName):
            // Pre-load the scenario just to read the briefing-picture
            // name; failures degrade gracefully to a briefing without
            // the sub-screen animation.
            let scenarioHit = (try? assets.loadScenario(named: scenarioName)) ?? nil
            let rawBrief = scenarioHit?.briefing.briefPicture ?? ""
            let briefingWsa: String? = rawBrief.isEmpty ? nil : rawBrief
            let scene = MentatScene(
                assets: assets,
                playerHouseID: MentatScene.playerHouse(forScenarioName: scenarioName),
                scenarioName: scenarioName,
                briefingWsaName: briefingWsa
            )
            present(scene)
        case .scenario(let name):
            // Kick off background music on scenario entry as well,
            // since the main-menu detour is no longer in the boot path.
            // `play` is a no-op if the jukebox is already running.
            _ = try? jukebox.play(named: "DUNE0.XMI")
            present(ScenarioScene(assets: assets, scenarioName: name))
        }
    }

    // MARK: - Private helpers

    private func present(_ scene: SKScene) {
        // Wire up the coordinator by scene type.
        if let s = scene as? IntroScene { s.coordinator = self }
        if let s = scene as? MainMenuScene { s.coordinator = self }
        if let s = scene as? MentatScene { s.coordinator = self }
        if let s = scene as? ScenarioScene { s.coordinator = self }
        skView.presentScene(scene)
    }
}
