import DuneIIAudio
import DuneIIContracts
import DuneIIFormats
import DuneIIInput
import DuneIISimulation
import DuneIIWorld
import Foundation

/// View model: owns the asset store + the scene, loads a scenario into a `Simulation`, applies zoom, and
/// mirrors the scene's player-input state (the selected unit/structure + any armed order) for the inspector.
@MainActor
@Observable
final class MapModel {
    let assets: AssetStore
    let scene = MapScene()
    private(set) var currentScenario: String?
    var scale: Int = 2 { didSet { scene.setZoom(CGFloat(scale)) } }
    var showFog: Bool = false { didSet { scene.showFog = showFog } }

    /// The selected entity's live properties (nil = nothing selected) + any armed order — published by the
    /// scene whenever they change. The inspector panel renders these.
    private(set) var selection: SelectionInfo?
    private(set) var pendingOrder: OrderKind?

    /// Low-latency, polyphonic audio: feedback sounds play instantly on the player's clicks (and mix when
    /// they overlap). Degrades to silent on a box with no audio device.
    private let audio = EngineAudioSink()

    init(assets: AssetStore) {
        self.assets = assets
        scene.configure()
        scene.setZoom(CGFloat(scale))
        scene.onStateChange = { [weak self] info, pending in
            self?.selection = info
            self?.pendingOrder = pending
        }
        setupAudio()
        if let first = assets.scenarioNames.first { load(first) }
    }

    /// Pre-decode the feedback VOCs into the sink (no load latency at play time), start the engine, and
    /// route the scene's `onSound` to it.
    private func setupAudio() {
        register("CLICK.VOC", as: .select)
        register("AFFIRM.VOC", as: .acknowledge)
        audio.start()
        scene.onSound = { [weak self] id in self?.audio.play(SoundEvent(sound: id)) }
    }

    private func register(_ voc: String, as id: SoundID) {
        guard let sound = assets.data(voc).flatMap({ try? Voc.decode($0) }) else { return }
        audio.register(id, sampleRate: sound.sampleRate, pcm8: sound.samples)
    }

    // Inspector actions → the scene's input controller.
    func arm(_ kind: OrderKind) { scene.beginOrder(kind) }
    func stopSelected() { scene.stopSelected() }
    func deselect() { scene.deselect() }

    func load(_ scenarioName: String) {
        guard let ini = assets.scenarioINI(scenarioName), let iconMap = assets.iconMap else { return }

        // Bridge the EMC scripts from the install so the scenario runs *live*: units move/aim/fire, and
        // structures run their BUILD.EMC scripts (turrets defend, refineries refine, a destroyed building
        // runs its death branch + is removed). Without these the map is static.
        let unitScript = assets.data("UNIT.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
        let structureScript = assets.data("BUILD.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)

        // Allocate every house so the House economy (GameLoop_House) ticks; point the viewport at the centre
        // so central units run their scripts full-speed (distant ones throttle, but still run).
        for h in 0 ..< 6 { _ = state.houseAllocate(index: UInt8(h)); state.houses[h].unitCountMax = 1000 }
        state.viewportPosition = Tile32.packXY(x: 32, y: 32)

        // Scen-style prepare: load each unit's action script + stamp it on the map (mirrors Game_Prepare),
        // so target resolution / occupancy work before the loop runs.
        if let unitScript {
            let setup = UnitActions()
            for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
                setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: unitScript, in: &state)
                state.unitUpdateMap(1, slot)
            }
        }

        let simulation = Simulation(
            state: state,
            scriptInfo: unitScript,
            structureScriptInfo: structureScript,
            tickExplosions: true,
            tickAnimations: true
        )  // visual app, not golden-pinned
        currentScenario = scenarioName
        scene.load(simulation: simulation, assets: assets)
        scene.setZoom(CGFloat(scale))
    }
}
