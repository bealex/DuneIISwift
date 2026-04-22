import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Simulation.Units.orderMove` — the pure-sim side of the
/// unit-selection slice. Mirrors OpenDUNE's `Unit_SetDestination` tail
/// (`src/unit.c:731`) for the tile-encoded case: write `targetMove`,
/// reset `route[0]`, clear `currentDestination{X,Y}`, set
/// `actionID = ActionID.move` (1) so the scheduler's per-unit engine
/// reloads at the MOVE entry point on its next tick.
@Suite("Units.orderMove — player move-order bridge")
struct UnitOrderMoveTests {

    // MARK: Happy path

    @Test("orderMove writes targetMove, actionID, clears route + currentDestination")
    func happyPath() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 0)  // Trike / Harkonnen
        var u = units[0]
        u.positionX = 256
        u.positionY = 256
        u.actionID = Simulation.ActionID.guard_  // 3
        u.route[0] = 2  // stale route step
        u.currentDestinationX = 1234
        u.currentDestinationY = 5678
        units[0] = u

        let ok = Simulation.Units.orderMove(poolIndex: 0, tileX: 10, tileY: 7, units: &units)
        #expect(ok)

        let expected = Scripting.EncodedIndex.tile(packed: 7 * 64 + 10).raw
        #expect(units[0].targetMove == expected)
        #expect(units[0].actionID == Simulation.ActionID.move)
        #expect(units[0].route[0] == 0xFF)
        #expect(units[0].currentDestinationX == 0)
        #expect(units[0].currentDestinationY == 0)
    }

    // MARK: Rejection paths (must not mutate pool)

    @Test("orderMove on unallocated slot returns false, pool unchanged")
    func rejectsUnallocated() {
        var units = Simulation.UnitPool()
        let before = units
        let ok = Simulation.Units.orderMove(poolIndex: 0, tileX: 10, tileY: 7, units: &units)
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderMove on freed slot returns false")
    func rejectsFreed() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 0)
        units.free(at: 0)
        let before = units
        let ok = Simulation.Units.orderMove(poolIndex: 0, tileX: 10, tileY: 7, units: &units)
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderMove rejects out-of-range pool index")
    func rejectsOutOfRange() {
        var units = Simulation.UnitPool()
        let before = units
        _ = Simulation.Units.orderMove(poolIndex: -1, tileX: 5, tileY: 5, units: &units)
        _ = Simulation.Units.orderMove(poolIndex: 200, tileX: 5, tileY: 5, units: &units)
        #expect(units == before)
    }

    @Test("orderMove rejects out-of-range tile coords")
    func rejectsOutOfRangeTiles() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 0)
        let before = units[0]
        _ = Simulation.Units.orderMove(poolIndex: 0, tileX: -1, tileY: 5, units: &units)
        _ = Simulation.Units.orderMove(poolIndex: 0, tileX: 64, tileY: 5, units: &units)
        _ = Simulation.Units.orderMove(poolIndex: 0, tileX: 5, tileY: -1, units: &units)
        _ = Simulation.Units.orderMove(poolIndex: 0, tileX: 5, tileY: 64, units: &units)
        #expect(units[0] == before)
    }

    // MARK: Semantic quirks

    @Test("orderMove overwrites an existing targetMove — always the freshest")
    func overwritesExistingTarget() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 0)
        var u = units[0]
        u.targetMove = Scripting.EncodedIndex.tile(packed: 0).raw
        u.actionID = Simulation.ActionID.move
        units[0] = u

        _ = Simulation.Units.orderMove(poolIndex: 0, tileX: 20, tileY: 30, units: &units)
        let expected = Scripting.EncodedIndex.tile(packed: 30 * 64 + 20).raw
        #expect(units[0].targetMove == expected)
    }

    @Test("orderMove on a unit standing on the destination tile still writes (scheduler no-ops)")
    func ordersStandOnTile() {
        // Hunts the edge case where a player right-clicks the tile
        // their unit is already on. The scheduler's arrival-threshold
        // check (≤ 16 px manhattan) clears targetMove on the next
        // tick, so this is effectively a no-op at the sim layer.
        // orderMove itself doesn't filter — UI layer can if desired.
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 0)
        var u = units[0]
        u.positionX = 10 * 256 + 128  // tile-centred at (10, 7)
        u.positionY = 7 * 256 + 128
        units[0] = u

        let ok = Simulation.Units.orderMove(poolIndex: 0, tileX: 10, tileY: 7, units: &units)
        #expect(ok)
        #expect(units[0].targetMove != 0)
    }

    // MARK: Scheduler integration

    @Test("orderMove → scheduler tick walks unit toward destination")
    func integrationWalksTowardDestination() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 0)  // Trike / wheeled
        var u = units[0]
        u.positionX = 10 * 256 + 128  // tile (10, 10) centre
        u.positionY = 10 * 256 + 128
        u.speed = 128                 // step = max(4, 32) = 32 px/tick
        units[0] = u

        _ = Simulation.Units.orderMove(poolIndex: 0, tileX: 20, tileY: 10, units: &units)

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: [], voiceLog: []
        )
        let emptyFunctions = [Scripting.VM.Function?](repeating: nil, count: 64)
        var scheduler = Simulation.Scheduler(
            host: host,
            unitVM: Scripting.VM(program: .empty, functions: emptyFunctions),
            structureVM: Scripting.VM(program: .empty, functions: emptyFunctions)
        )
        let xBefore = host.units[0].positionX
        scheduler.tick()
        #expect(host.units[0].positionX > xBefore)
    }
}
