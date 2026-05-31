import DuneIIContracts
import DuneIIFormats
import DuneIIInput
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation
import SpriteKit

/// SpriteKit scene that draws a live `Simulation` through the engine's `FrameInfo` seam and drives **player
/// input**: each frame it applies queued `Command`s, advances the sim one tick, snapshots a `FrameInfo`,
/// and renders it. Mouse clicks select a unit/structure (left) or order the selected unit (right); the
/// `InputController` (a Contracts-bound `DuneIIInput` state machine) turns those into `Command`s the scene
/// applies via `UnitOrders`. The selected entity is outlined and its live properties published to the
/// inspector via `onStateChange`.
@MainActor
final class MapScene: SKScene {
    private static let worldSidePx = 16 * 64   // base scale: 16px tiles over the 64×64 map
    private static let tileSize = 16

    private let cam = SKCameraNode()
    private var simulation: Simulation?
    private var renderer: SpriteKitRenderer?
    private var unitScript: ScriptInfo?

    private var controller = InputController(mapWidth: 64)
    private let selectionNode = SKShapeNode()
    /// Published whenever the selection / armed order / selected entity's stats change (the inspector reads it).
    var onStateChange: ((SelectionInfo?, OrderKind?) -> Void)?
    private var lastPublished: (SelectionInfo?, OrderKind?)?

    func configure() {
        let side = CGFloat(Self.worldSidePx)
        size = CGSize(width: side, height: side)
        scaleMode = .aspectFit
        backgroundColor = SKColor.black
        addChild(cam)
        camera = cam
        cam.position = CGPoint(x: side / 2, y: side / 2)

        selectionNode.strokeColor = .white
        selectionNode.lineWidth = 1.5
        selectionNode.fillColor = .clear
        selectionNode.zPosition = 20
        selectionNode.isHidden = true
        addChild(selectionNode)
    }

    func setZoom(_ factor: CGFloat) { cam.setScale(1 / max(factor, 1)) }

    var showFog: Bool = false {
        didSet {
            guard let renderer, let simulation, showFog != oldValue else { return }
            renderer.showFog = showFog
            renderer.rebuildTerrain(simulation.makeFrameInfo())
        }
    }

    func load(simulation: Simulation, assets: AssetStore) {
        self.simulation = simulation
        self.unitScript = assets.data("UNIT.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
        controller.deselect()
        for child in children where child !== cam && child !== selectionNode { child.removeFromParent() }

        let renderer = SpriteKitRenderer(source: MapSpriteSource.make(assets: assets), basePalette: assets.palette)
        renderer.attach(to: self)
        renderer.render(simulation.makeFrameInfo())
        self.renderer = renderer
        publishState()
    }

    /// The game loop: apply queued player commands, advance the sim, redraw, then refresh the selection.
    override func update(_ currentTime: TimeInterval) {
        guard simulation != nil, let renderer else { return }
        applyCommands()
        simulation!.tick()
        renderer.render(simulation!.makeFrameInfo())
        refreshSelection()
    }

    private func applyCommands() {
        let commands = controller.drainCommands()
        guard !commands.isEmpty, let unitScript else { return }
        let orders = UnitOrders(scriptInfo: unitScript)
        for command in commands { orders.apply(command, in: &simulation!.state) }
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        guard let (x, y) = tile(at: event) else { return }
        controller.leftClick(tileX: x, tileY: y, hit: pick(tileX: x, tileY: y))
        publishState()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let (x, y) = tile(at: event) else { return }
        controller.rightClick(tileX: x, tileY: y, enemyTarget: isEnemyOfSelected(tileX: x, tileY: y))
        publishState()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
            case 53: deselect()                 // Escape
            case 1:  stopSelected()             // S
            case 0:  beginOrder(.attack)        // A
            default: super.keyDown(with: event)
        }
    }

    /// The map tile under a mouse event (scene coords are y-up; the world is y-down). `nil` if off-map.
    private func tile(at event: NSEvent) -> (Int, Int)? {
        let p = event.location(in: self)
        let x = Int(p.x) / Self.tileSize
        let y = (Self.worldSidePx - Int(p.y)) / Self.tileSize
        guard (0 ..< 64).contains(x), (0 ..< 64).contains(y) else { return nil }
        return (x, y)
    }

    /// The selectable entity at a tile: the unit there, else a structure, else nothing.
    private func pick(tileX x: Int, tileY y: Int) -> Selection {
        guard let state = simulation?.state else { return .none }
        let packed = UInt16(y * 64 + x)
        if let u = state.unitGetByPackedTile(packed) { return .unit(slot: u) }
        if let s = state.structureGetByPackedTile(packed) { return .structure(slot: s) }
        return .none
    }

    /// Whether the tile holds an entity of a different house than the selected unit (→ attack, not move).
    private func isEnemyOfSelected(tileX x: Int, tileY y: Int) -> Bool {
        guard let state = simulation?.state, let slot = controller.selection.unitSlot,
              slot < state.units.count else { return false }
        let myHouse = state.unitHouseID(state.units[slot])
        let packed = UInt16(y * 64 + x)
        if let u = state.unitGetByPackedTile(packed) { return state.unitHouseID(state.units[u]) != myHouse }
        if let s = state.structureGetByPackedTile(packed) { return state.structures[s].o.houseID != myHouse }
        return false
    }

    // MARK: - Inspector actions (forwarded from the model)

    func beginOrder(_ kind: OrderKind) { controller.beginOrder(kind); publishState() }
    func stopSelected() { controller.stopSelected(); publishState() }
    func deselect() { controller.deselect(); publishState() }

    // MARK: - Selection highlight + publishing

    /// Reposition the outline over the live selected entity (it moves), drop a dead selection.
    private func refreshSelection() {
        guard let info = currentInfo() else {
            if !controller.selection.isEmpty { controller.deselect() }   // the entity died/was removed
            selectionNode.isHidden = true
            publishState()
            return
        }
        // Place the outline over the entity's footprint in scene (y-up) coordinates.
        let (tilesW, tilesH) = footprint()
        let w = tilesW * Self.tileSize, h = tilesH * Self.tileSize
        let originX = info.tileX * Self.tileSize
        let topY = Self.worldSidePx - (info.tileY + tilesH) * Self.tileSize   // y-flip the top-left
        selectionNode.path = CGPath(rect: CGRect(x: originX, y: topY, width: w, height: h), transform: nil)
        selectionNode.isHidden = false
        publishState()
    }

    private func footprint() -> (Int, Int) {
        guard case let .structure(slot) = controller.selection, let state = simulation?.state,
              slot < state.structures.count,
              let type = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return (1, 1) }
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        return (Int(layout.size.width), Int(layout.size.height))
    }

    /// The live properties of the current selection, or `nil` if nothing valid is selected.
    private func currentInfo() -> SelectionInfo? {
        guard let state = simulation?.state else { return nil }
        switch controller.selection {
            case .none: return nil
            case let .unit(slot):
                guard slot < state.units.count, state.units[slot].o.flags.contains(.used),
                      let type = UnitType(rawValue: Int(state.units[slot].o.type)) else { return nil }
                let u = state.units[slot]
                let house = HouseID(rawValue: Int(state.unitHouseID(u))) ?? .harkonnen
                let packed = Int(u.o.position.packed)
                return SelectionInfo(kind: .unit, name: type.displayName, house: house.displayName,
                                     hitpoints: Int(u.o.hitpoints), hitpointsMax: Int(UnitInfo[type].o.hitpoints),
                                     tileX: packed % 64, tileY: packed / 64)
            case let .structure(slot):
                guard slot < state.structures.count, state.structures[slot].o.flags.contains(.used),
                      let type = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return nil }
                let s = state.structures[slot]
                let house = HouseID(rawValue: Int(s.o.houseID)) ?? .harkonnen
                let packed = Int(s.o.position.packed)
                return SelectionInfo(kind: .structure, name: type.displayName, house: house.displayName,
                                     hitpoints: Int(s.o.hitpoints), hitpointsMax: Int(s.hitpointsMax),
                                     tileX: packed % 64, tileY: packed / 64)
        }
    }

    /// Publish to the inspector only when the shown state actually changes (avoids 60 Hz SwiftUI churn).
    private func publishState() {
        let next = (currentInfo(), controller.pendingOrder)
        if let last = lastPublished, last.0 == next.0, last.1 == next.1 { return }
        lastPublished = next
        onStateChange?(next.0, next.1)
    }
}
