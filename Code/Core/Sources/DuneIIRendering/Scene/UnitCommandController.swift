import Foundation
import DuneIICore
import Memoirs

/// Pure state machine bridging `ScenarioScene` mouse events to the unit
/// pool. Testable without SpriteKit.
///
/// Left-click on any unit tile (friendly or enemy) selects that unit;
/// the `isFriendlySelection` flag tells the scene whether to display
/// action buttons. Right-click issues orders only when the selection
/// is friendly — enemy selections are info-only.
///
/// See `Documentation/Algorithms/UnitSelectionAndOrders.md`.
public struct UnitCommandController: Equatable, Sendable {
    /// Pool slot of the currently-selected unit (friendly OR enemy).
    /// `nil` when nothing is selected or the last-selected slot has
    /// been freed (auto-cleared on the next click).
    public var selectedUnitIndex: Int?
    /// `true` when the selected unit is owned by the player, `false`
    /// when it's an enemy / ally. Right-click actions are silently
    /// dropped when this is `false` — enemy selections are info-only.
    public var isFriendlySelection: Bool

    /// Staged action primed by a keyboard shortcut (A/M/H/R on the
    /// scene). The next left-click on the map resolves it as an
    /// order targeting the clicked tile, then clears the stage.
    /// `nil` means "normal left-click behaviour" (select / deselect).
    public enum StagedAction: Equatable, Sendable {
        case attack
        case move
        case harvest
        case returnAction
    }
    public var stagedAction: StagedAction?

    public init(
        selectedUnitIndex: Int? = nil,
        isFriendlySelection: Bool = false,
        stagedAction: StagedAction? = nil
    ) {
        self.selectedUnitIndex = selectedUnitIndex
        self.isFriendlySelection = isFriendlySelection
        self.stagedAction = stagedAction
    }

    /// Primes a keyboard-staged action. Returns `true` when the
    /// shortcut is valid for the current selection (friendly unit
    /// selected; harvest/return additionally require a HARVESTER).
    /// Invalid presses clear any existing stage so stray keys don't
    /// leave the controller in a confusing state.
    @discardableResult
    public mutating func stage(
        action: StagedAction, pool: Simulation.UnitPool
    ) -> Bool {
        guard let sel = selectedUnitIndex,
              isFriendlySelection,
              sel < pool.slots.count, pool.slots[sel].isUsed else {
            stagedAction = nil
            return false
        }
        let unit = pool.slots[sel]
        if action == .harvest || action == .returnAction {
            // Only harvesters can do harvest/return (type 16).
            guard unit.type == 16 else {
                stagedAction = nil
                return false
            }
        }
        stagedAction = action
        return true
    }

    /// Mouse events the scene forwards. Bound to `mouseDown` /
    /// `rightMouseDown`; sidebar + off-map clicks go to the build panel
    /// controller instead.
    public enum Click: Equatable, Sendable {
        case leftMapTile(x: Int, y: Int)
        case rightMapTile(x: Int, y: Int)
    }

    /// Scene-observable result.
    public enum Action: Equatable, Sendable {
        case none
        /// Unit selected. `isFriendly` tells the scene whether to render
        /// action affordances (only friendly units show them).
        case selectUnit(poolIndex: Int, isFriendly: Bool)
        case deselect
        case orderMove(poolIndex: Int, tileX: Int, tileY: Int)
        case orderAttack(attackerIndex: Int, targetIndex: Int)
        /// Attack order against an enemy structure. Runtime calls
        /// `Simulation.Units.orderAttackStructure(...)`.
        case orderAttackStructure(attackerIndex: Int, targetStructureIndex: Int)
        /// Harvest order: harvester will seek/drain spice starting at
        /// the staged tile (harvester-only shortcut).
        case orderHarvest(poolIndex: Int, tileX: Int, tileY: Int)
        /// Return order: harvester heads home to its nearest refinery
        /// (harvester-only shortcut; runtime picks the destination).
        case orderReturn(poolIndex: Int)
    }

    public mutating func handle(
        click: Click,
        pool: Simulation.UnitPool,
        playerHouseID: UInt8,
        structures: Simulation.StructurePool = Simulation.StructurePool()
    ) -> Action {
        // Auto-clear a stale selection (e.g. a unit died between the
        // last and current click).
        if let sel = selectedUnitIndex,
           sel < 0 || sel >= pool.slots.count || !pool.slots[sel].isUsed {
            Log.debug(
                "unit-cmd stale selection \(sel) cleared",
                tracer: .label("unit-cmd")
            )
            selectedUnitIndex = nil
            isFriendlySelection = false
        }

        switch click {
        case .leftMapTile(let x, let y):
            // If a shortcut is staged, resolve it against the clicked
            // tile instead of running the select/deselect machinery.
            // Staged actions are keyboard-driven (`ScenarioScene`
            // keyDown → `stage(action:pool:)`); they only survive when
            // a friendly unit is still selected (the stage call
            // validates that — but guard again in case the selection
            // died between stage and click).
            if let staged = stagedAction,
               let sel = selectedUnitIndex, isFriendlySelection
            {
                // Always clear the stage after one click, whether it
                // produced an order or not.
                stagedAction = nil
                switch staged {
                case .move:
                    return .orderMove(poolIndex: sel, tileX: x, tileY: y)
                case .attack:
                    if let enemy = Self.unitAtTile(
                        x: x, y: y, pool: pool,
                        matching: { $0.houseID != playerHouseID }
                    ), enemy != sel {
                        return .orderAttack(attackerIndex: sel, targetIndex: enemy)
                    }
                    if let structIdx = Self.enemyStructureAtTile(
                        x: x, y: y, pool: structures, playerHouseID: playerHouseID
                    ) {
                        return .orderAttackStructure(
                            attackerIndex: sel, targetStructureIndex: structIdx
                        )
                    }
                    // Force-attack on empty tile falls back to move.
                    return .orderMove(poolIndex: sel, tileX: x, tileY: y)
                case .harvest:
                    return .orderHarvest(poolIndex: sel, tileX: x, tileY: y)
                case .returnAction:
                    return .orderReturn(poolIndex: sel)
                }
            }

            // Prefer friendly under the click so right-click commands
            // work without needing a second click; fall back to any
            // unit for info-only enemy selection.
            if let friendly = Self.unitAtTile(
                x: x, y: y, pool: pool,
                matching: { $0.houseID == playerHouseID }
            ) {
                selectedUnitIndex = friendly
                isFriendlySelection = true
                return .selectUnit(poolIndex: friendly, isFriendly: true)
            }
            if let other = Self.unitAtTile(
                x: x, y: y, pool: pool,
                matching: { $0.houseID != playerHouseID }
            ) {
                selectedUnitIndex = other
                isFriendlySelection = false
                return .selectUnit(poolIndex: other, isFriendly: false)
            }
            if selectedUnitIndex != nil {
                selectedUnitIndex = nil
                isFriendlySelection = false
                return .deselect
            }
            return .none

        case .rightMapTile(let x, let y):
            guard let sel = selectedUnitIndex, isFriendlySelection else {
                return .none
            }
            if let enemy = Self.unitAtTile(
                x: x, y: y, pool: pool,
                matching: { $0.houseID != playerHouseID }
            ), enemy != sel {
                return .orderAttack(attackerIndex: sel, targetIndex: enemy)
            }
            // Enemy structure at this tile? Attack it.
            if let structIdx = Self.enemyStructureAtTile(
                x: x, y: y, pool: structures, playerHouseID: playerHouseID
            ) {
                return .orderAttackStructure(
                    attackerIndex: sel, targetStructureIndex: structIdx
                )
            }
            return .orderMove(poolIndex: sel, tileX: x, tileY: y)
        }
    }

    /// Returns the pool index of a non-player-owned structure whose
    /// footprint covers `(x, y)`, or `nil`.
    private static func enemyStructureAtTile(
        x: Int, y: Int,
        pool: Simulation.StructurePool,
        playerHouseID: UInt8
    ) -> Int? {
        guard (0..<64).contains(x), (0..<64).contains(y) else { return nil }
        for idx in pool.findArray {
            let s = pool.slots[idx]
            guard s.isUsed, s.isAllocated else { continue }
            guard s.houseID != playerHouseID else { continue }
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            if footprint.contains(where: { $0.0 == x && $0.1 == y }) {
                return idx
            }
        }
        return nil
    }

    /// Finds the first unit in `pool.findArray` sitting on `(x, y)`
    /// that satisfies `predicate`. Generalises the previous
    /// friendly/enemy helpers into one scan.
    private static func unitAtTile(
        x: Int, y: Int,
        pool: Simulation.UnitPool,
        matching predicate: (Simulation.UnitSlot) -> Bool
    ) -> Int? {
        guard (0..<64).contains(x), (0..<64).contains(y) else { return nil }
        for idx in pool.findArray {
            let slot = pool.slots[idx]
            if !slot.isUsed { continue }
            let tx = Int(slot.positionX) / 256
            let ty = Int(slot.positionY) / 256
            guard tx == x, ty == y else { continue }
            if predicate(slot) { return idx }
        }
        return nil
    }
}
