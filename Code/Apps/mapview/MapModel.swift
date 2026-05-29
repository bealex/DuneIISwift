import DuneIISimulation
import DuneIIWorld
import Foundation

/// View model: owns the asset store + the scene, loads a scenario into a `Simulation`, and applies zoom.
@MainActor
@Observable
final class MapModel {
    let assets: AssetStore
    let scene = MapScene()
    private(set) var currentScenario: String?
    var scale: Int = 2 { didSet { scene.setZoom(CGFloat(scale)) } }

    init(assets: AssetStore) {
        self.assets = assets
        scene.configure()
        scene.setZoom(CGFloat(scale))
        if let first = assets.scenarioNames.first { load(first) }
    }

    func load(_ scenarioName: String) {
        guard let ini = assets.scenarioINI(scenarioName), let iconMap = assets.iconMap else { return }
        var simulation = Simulation()
        simulation.state.loadScenario(ini: ini, iconMap: iconMap)
        currentScenario = scenarioName
        scene.load(simulation: simulation, assets: assets)
        scene.setZoom(CGFloat(scale))
    }
}
