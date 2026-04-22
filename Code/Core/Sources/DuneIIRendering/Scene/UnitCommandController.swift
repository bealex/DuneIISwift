import Foundation
import DuneIICore

/// Pure state machine bridging `ScenarioScene` mouse events to the unit
/// pool. Testable without SpriteKit. Mirrors `BuildPanelController` in
/// shape; stays narrow in scope — single-unit selection + move orders
/// (slice 1). Drag-select, attack, harvest, shift-additive all deferred.
///
/// See `Documentation/Algorithms/UnitSelectionAndOrders.md`.
public struct UnitCommandController: Equatable, Sendable {
    /// Pool slot of the currently-selected friendly unit. `nil` when
    /// nothing is selected, or when the last-selected slot has been
    /// freed (the controller auto-clears stale references on the next
    /// click).
    public var selectedUnitIndex: Int?

    public init(selectedUnitIndex: Int? = nil) {
        self.selectedUnitIndex = selectedUnitIndex
    }

    /// Mouse events the scene forwards. Bound to `mouseDown` /
    /// `rightMouseDown`; sidebar + off-map clicks go to the build panel
    /// controller instead.
    public enum Click: Equatable, Sendable {
        case leftMapTile(x: Int, y: Int)
        case rightMapTile(x: Int, y: Int)
    }

    /// Scene-observable result. `selectUnit` / `deselect` are
    /// selection-state changes the scene renders as a halo; `orderMove`
    /// is a pool mutation the scene applies via
    /// `Simulation.Units.orderMove`.
    public enum Action: Equatable, Sendable {
        case none
        case selectUnit(poolIndex: Int)
        case deselect
        case orderMove(poolIndex: Int, tileX: Int, tileY: Int)
    }

    public mutating func handle(
        click: Click,
        pool: Simulation.UnitPool,
        playerHouseID: UInt8
    ) -> Action {
        // Auto-clear a stale selection (e.g. a unit died between the
        // last and current click). This keeps the controller robust
        // without requiring the scene to push pool-state deltas.
        if let sel = selectedUnitIndex,
           sel < 0 || sel >= pool.slots.count || !pool.slots[sel].isUsed {
            selectedUnitIndex = nil
        }

        switch click {
        case .leftMapTile(let x, let y):
            if let friendly = Self.friendlyUnitAtTile(
                x: x, y: y, pool: pool, playerHouseID: playerHouseID
            ) {
                selectedUnitIndex = friendly
                return .selectUnit(poolIndex: friendly)
            }
            // No friendly under the click: if something was selected,
            // clear it; otherwise this is an inert click.
            if selectedUnitIndex != nil {
                selectedUnitIndex = nil
                return .deselect
            }
            return .none

        case .rightMapTile(let x, let y):
            guard let sel = selectedUnitIndex else { return .none }
            return .orderMove(poolIndex: sel, tileX: x, tileY: y)
        }
    }

    /// Scans the pool's `findArray` for a friendly unit whose position
    /// tile matches `(x, y)`. Returns the pool slot index, or `nil`.
    /// Enemy units are deliberately invisible to this query — left-click
    /// on an enemy tile collapses to the "empty terrain" path in slice
    /// 1 (attack orders land in a later slice).
    private static func friendlyUnitAtTile(
        x: Int, y: Int, pool: Simulation.UnitPool, playerHouseID: UInt8
    ) -> Int? {
        guard (0..<64).contains(x), (0..<64).contains(y) else { return nil }
        for idx in pool.findArray {
            let slot = pool.slots[idx]
            if !slot.isUsed { continue }
            if slot.houseID != playerHouseID { continue }
            let tx = Int(slot.positionX) / 256
            let ty = Int(slot.positionY) / 256
            if tx == x && ty == y { return idx }
        }
        return nil
    }
}
