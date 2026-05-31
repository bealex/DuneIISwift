import CoreGraphics
import DuneIIAudio
import DuneIIContracts
import DuneIIFormats
import DuneIIInput
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation

/// The client's central state, shared by the map window + every tool window. Owns the live `Simulation`,
/// the input controller (selection/orders), the camera `Viewport` (scroll/zoom), the player house, the
/// debug toggles, and the derived per-frame info the panels read (selection, economy, minimap, last frame).
/// `@Observable`, so the SwiftUI windows update reactively.
@MainActor
@Observable
final class GameModel {
    let assets: AssetStore
    @ObservationIgnored let audio = EngineAudioSink()
    @ObservationIgnored var scene: GameScene!

    private(set) var currentScenario: String?
    private(set) var simulation: Simulation?
    @ObservationIgnored private var unitScript: ScriptInfo?
    @ObservationIgnored private var controller = InputController(mapWidth: 64)

    /// Camera. The scene applies it; the minimap reads it.
    var viewport = Viewport()
    /// The map view's pixel size in points (the scene keeps this current for scroll/zoom clamping).
    @ObservationIgnored var viewSize = CGSize(width: 1024, height: 768)

    private(set) var playerHouse: HouseID = .atreides

    // Debug toggles (the Debug window binds these; the scene/economy/fog read them).
    var showFog = false { didSet { scene?.applyFog() } }
    var showAllEconomies = false
    var showHealthOverlay = false

    // Derived per-frame info for the tool windows.
    private(set) var selection: SelectionInfo?
    private(set) var pendingOrder: OrderKind?
    private(set) var economy: [HouseEconomy] = []
    /// The latest frame — observed, so the minimap redraws each tick (units/viewport move).
    private(set) var lastFrame: FrameInfo?
    @ObservationIgnored private(set) var minimapBase: CGImage?

    /// Which tool windows are open (mirrored by the window manager; the toolbar toggles read this).
    var openTools: Set<ToolKind> = Set(ToolKind.allCases)

    init(assets: AssetStore) {
        self.assets = assets
        scene = GameScene(model: self)
        setupAudio()
        if let first = assets.scenarioNames.first { load(first) }
    }

    // MARK: - Loading

    func load(_ scenarioName: String) {
        guard let ini = assets.scenarioINI(scenarioName), let iconMap = assets.iconMap else { return }
        unitScript = assets.data("UNIT.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
        let structureScript = assets.data("BUILD.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)
        for h in 0 ..< 6 { _ = state.houseAllocate(index: UInt8(h)); state.houses[h].unitCountMax = 1000 }
        playerHouse = AssetStore.playerHouse(in: ini)
            ?? state.houses.first(where: { $0.flags.contains(.used) }).flatMap { HouseID(rawValue: Int($0.index)) }
            ?? .atreides
        state.playerHouseID = UInt8(playerHouse.rawValue)
        state.viewportPosition = Tile32.packXY(x: 32, y: 32)

        if let unitScript {
            let setup = UnitActions()
            for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
                setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: unitScript, in: &state)
                state.unitUpdateMap(1, slot)
            }
        }

        let sim = Simulation(state: state, scriptInfo: unitScript, structureScriptInfo: structureScript,
                             tickExplosions: true, tickAnimations: true)
        simulation = sim
        currentScenario = scenarioName
        controller.deselect()
        viewport = Viewport()
        scene.load(simulation: sim, assets: assets)
        let frame = sim.makeFrameInfo()
        lastFrame = frame
        minimapBase = Minimap.baseImage(frame: frame, source: SpriteSource.make(assets: assets), palette: assets.palette)
        refreshDerived(frame)
    }

    private func setupAudio() {
        if let s = assets.voc("CLICK.VOC") { audio.register(.select, sampleRate: s.sampleRate, pcm8: s.samples) }
        if let s = assets.voc("AFFIRM.VOC") { audio.register(.acknowledge, sampleRate: s.sampleRate, pcm8: s.samples) }
        audio.start()
    }

    // MARK: - Per-frame loop (driven by the scene)

    /// Apply queued commands, advance the sim one tick, and refresh the derived info; returns the frame.
    func advance() -> FrameInfo? {
        guard var sim = simulation else { return nil }
        if let unitScript {
            let commands = controller.drainCommands()
            if !commands.isEmpty {
                let orders = UnitOrders(scriptInfo: unitScript)
                for c in commands { orders.apply(c, in: &sim.state) }
            }
        }
        sim.tick()
        simulation = sim
        let frame = sim.makeFrameInfo()
        lastFrame = frame
        refreshDerived(frame)
        return frame
    }

    private func refreshDerived(_ frame: FrameInfo) {
        // Drop a dead selection, then republish only when something the panels show actually changed
        // (guarded so the per-tick refresh doesn't churn SwiftUI 60×/sec).
        if currentInfo() == nil && !controller.selection.isEmpty { controller.deselect() }
        let info = currentInfo()
        if info != selection { selection = info }
        if controller.pendingOrder != pendingOrder { pendingOrder = controller.pendingOrder }
        let econ = frame.houses
            .filter { showAllEconomies || $0.id == playerHouse }
            .map { HouseEconomy(house: $0.id.displayName, isPlayer: $0.id == playerHouse,
                                credits: $0.credits, storage: $0.creditsStorage,
                                power: $0.powerProduction, powerUsed: $0.powerUsage) }
        if econ != economy { economy = econ }
    }

    // MARK: - Input (forwarded from the scene's mouse handling)

    var selectionSlot: Selection { controller.selection }

    func leftClickTile(_ x: Int, _ y: Int) {
        let hit = pick(x, y)
        let wasArmed = controller.pendingOrder != nil && controller.selection.unitSlot != nil
        controller.leftClick(tileX: x, tileY: y, hit: hit)
        if wasArmed { audio.play(.acknowledge) } else if !hit.isEmpty { audio.play(.select) }
        pendingOrder = controller.pendingOrder
        selection = currentInfo()
    }

    func rightClickTile(_ x: Int, _ y: Int) {
        let willOrder = controller.selection.unitSlot != nil
        controller.rightClick(tileX: x, tileY: y, enemyTarget: isEnemy(x, y))
        if willOrder { audio.play(.acknowledge) }
        pendingOrder = controller.pendingOrder
    }

    // Inspector actions.
    func arm(_ kind: OrderKind) { controller.beginOrder(kind); audio.play(.select); pendingOrder = controller.pendingOrder }
    func stopSelected() { controller.stopSelected(); audio.play(.acknowledge) }
    func deselect() { controller.deselect(); selection = nil; pendingOrder = nil }

    private func pick(_ x: Int, _ y: Int) -> Selection {
        guard let state = simulation?.state else { return .none }
        let packed = UInt16(y * 64 + x)
        if let u = state.unitGetByPackedTile(packed) { return .unit(slot: u) }
        if let s = state.structureGetByPackedTile(packed) { return .structure(slot: s) }
        return .none
    }

    private func isEnemy(_ x: Int, _ y: Int) -> Bool {
        guard let state = simulation?.state, let slot = controller.selection.unitSlot, slot < state.units.count else { return false }
        let mine = state.unitHouseID(state.units[slot])
        let packed = UInt16(y * 64 + x)
        if let u = state.unitGetByPackedTile(packed) { return state.unitHouseID(state.units[u]) != mine }
        if let s = state.structureGetByPackedTile(packed) { return state.structures[s].o.houseID != mine }
        return false
    }

    // MARK: - Viewport (scroll/zoom + minimap)

    func zoomIn() { viewport.zoomIn() }
    func zoomOut() { viewport.zoomOut() }
    func scroll(dx: Double, dy: Double) { viewport.scroll(dx: dx, dy: dy, viewSize: viewSize) }
    /// Centre the map on a world point (a minimap click), in world points.
    func centerOn(worldX: Double, worldY: Double) { viewport.center(onWorldX: worldX, worldY: worldY, viewSize: viewSize) }

    // MARK: - Selection info derivation

    func selectionFootprint() -> (Int, Int) {
        guard case let .structure(slot) = controller.selection, let state = simulation?.state,
              slot < state.structures.count,
              let type = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return (1, 1) }
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        return (Int(layout.size.width), Int(layout.size.height))
    }

    func selectionTile() -> (Int, Int)? {
        guard let state = simulation?.state else { return nil }
        switch controller.selection {
            case let .unit(slot) where slot < state.units.count && state.units[slot].o.flags.contains(.used):
                let p = Int(state.units[slot].o.position.packed); return (p % 64, p / 64)
            case let .structure(slot) where slot < state.structures.count && state.structures[slot].o.flags.contains(.used):
                let p = Int(state.structures[slot].o.position.packed); return (p % 64, p / 64)
            default: return nil
        }
    }

    private func currentInfo() -> SelectionInfo? {
        guard let state = simulation?.state else { return nil }
        switch controller.selection {
            case .none: return nil
            case let .unit(slot):
                guard slot < state.units.count, state.units[slot].o.flags.contains(.used),
                      let type = UnitType(rawValue: Int(state.units[slot].o.type)) else { return nil }
                let u = state.units[slot]
                let house = HouseID(rawValue: Int(state.unitHouseID(u))) ?? .harkonnen
                let p = Int(u.o.position.packed)
                return SelectionInfo(kind: .unit, name: type.displayName, house: house.displayName,
                                     isPlayer: house == playerHouse, hitpoints: Int(u.o.hitpoints),
                                     hitpointsMax: Int(UnitInfo[type].o.hitpoints), tileX: p % 64, tileY: p / 64)
            case let .structure(slot):
                guard slot < state.structures.count, state.structures[slot].o.flags.contains(.used),
                      let type = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return nil }
                let s = state.structures[slot]
                let house = HouseID(rawValue: Int(s.o.houseID)) ?? .harkonnen
                let p = Int(s.o.position.packed)
                return SelectionInfo(kind: .structure, name: type.displayName, house: house.displayName,
                                     isPlayer: house == playerHouse, hitpoints: Int(s.o.hitpoints),
                                     hitpointsMax: Int(s.hitpointsMax), tileX: p % 64, tileY: p / 64)
        }
    }
}

/// A house's economy for the Economy window.
struct HouseEconomy: Equatable, Identifiable {
    var house: String
    var isPlayer: Bool
    var credits: Int, storage: Int, power: Int, powerUsed: Int
    var id: String { house }
}

/// The selected entity's properties for the Inspector window.
struct SelectionInfo: Equatable {
    enum Kind: Equatable { case unit, structure }
    var kind: Kind
    var name: String, house: String
    var isPlayer: Bool
    var hitpoints: Int, hitpointsMax: Int
    var tileX: Int, tileY: Int
    var commands: [OrderKind] { kind == .unit && isPlayer ? [.move, .attack] : [] }
    var canStop: Bool { kind == .unit && isPlayer }
}
