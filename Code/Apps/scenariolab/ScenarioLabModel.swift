import DuneIIContracts
import DuneIIScenarios
import Foundation

/// View model: holds the assets + scene and the current scenario selection (kind, two unit types,
/// terrain seed). Any change rebuilds the scenario; "regenerate" bumps the seed for a new terrain.
@MainActor
@Observable
final class ScenarioLabModel {
    let assets: ScenarioAssets
    let scene = ScenarioScene()

    var kind: ScenarioKind = .moving { didSet { rebuild() } }
    var unit1: UnitType = .tank { didSet { rebuild() } }
    var unit2: UnitType = .trike { didSet { rebuild() } }
    private(set) var seed: UInt32 = 1
    /// Display zoom: game-pixel → `scale` screen points (1× = point-to-pixel). Drives the view's square
    /// size in `ContentView`; the scene renders 1:1, so it's purely the on-screen size (no resim).
    var scale: Int = 4
    var running = false { didSet { scene.setRunning(running) } }
    /// Simulation speed: ticks run per rendered frame (1…10×). Higher fast-forwards the sim; the render
    /// still updates once per frame. Does not rebuild the scenario.
    var speed: Int = 1 { didSet { scene.setTicksPerFrame(speed) } }

    /// The selectable (real, non-bullet) unit types.
    let selectableUnits: [UnitType] = [
        .soldier, .infantry, .trooper, .troopers, .trike, .raiderTrike, .quad, .tank, .siegeTank,
        .launcher, .deviator, .sonicTank, .devastator, .harvester, .mcv, .saboteur, .carryall,
        .ornithopter, .sandworm,
    ]

    init(assets: ScenarioAssets) {
        self.assets = assets
        scene.configure()
        // The scene auto-pauses at the scenario's endpoint — reflect that in the toolbar's play/pause state.
        scene.onComplete = { [weak self] in self?.running = false }
        rebuild()
    }

    func regenerate() {
        seed &+= 1
        rebuild()
    }

    func name(_ u: UnitType) -> String { String(describing: u) }

    /// Rebuild the scenario from the current selection and **pause** — any change starts paused so the
    /// initial setup can be assessed before running.
    private func rebuild() {
        guard let builder = assets.builder else { return }

        running = false
        let scenario = TestScenario(kind: kind, unit1: unit1, unit2: unit2, terrainSeed: seed)
        var world = builder.build(scenario)
        world.tickExplosions = true  // the lab animates impacts/deaths/destruction (not golden-pinned)
        world.tickAnimations = true  // …and structure animations (power lights, factory cycles)
        scene.load(world: world, assets: assets, running: false)
    }
}
