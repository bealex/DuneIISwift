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
    var scale: Int = 8 { didSet { scene.setZoom(CGFloat(scale)) } }
    var running = true { didSet { scene.setRunning(running) } }

    /// The selectable (real, non-bullet) unit types.
    let selectableUnits: [UnitType] = [
        .soldier, .infantry, .trooper, .troopers, .trike, .raiderTrike, .quad, .tank, .siegeTank,
        .launcher, .deviator, .sonicTank, .devastator, .harvester, .mcv, .saboteur, .carryall,
        .ornithopter, .sandworm,
    ]

    init(assets: ScenarioAssets) {
        self.assets = assets
        scene.configure()
        scene.setZoom(CGFloat(scale))
        rebuild()
    }

    func regenerate() {
        seed &+= 1
        rebuild()
    }

    func name(_ u: UnitType) -> String { String(describing: u) }

    private func rebuild() {
        guard let builder = assets.builder else { return }
        let scenario = TestScenario(kind: kind, unit1: unit1, unit2: unit2, terrainSeed: seed)
        scene.load(world: builder.build(scenario), assets: assets, running: running)
    }
}
