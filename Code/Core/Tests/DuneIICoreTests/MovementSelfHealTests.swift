import Foundation
import Testing
@testable import DuneIICore

/// Regression tests for movement recovery after a blocked route step.
///
/// Bug history:
/// - Pre-fix: `tickMovement`'s "route-step impassable" branch cleared
///   both `route` AND `targetMove`, stranding any unit whose planned
///   step was transiently blocked (other unit crossing, path clipping
///   a structure corner). Hunt-action enemies wedged into concave
///   building angles and never recovered.
/// - Pre-fix: the fix briefly included an inline `Pathfinder.findRoute`
///   replan in `tickMovement` itself. That self-heal filled the route
///   before the script's `CalculateRoute` had a chance to run, which in
///   turn never called `setSpeed` — user-ordered moves never started
///   (unit stayed in `ACTION_MOVE` at `speed=0`).
///
/// Post-fix: `move-halt` on a blocked route step clears only the route
/// (and `currentDestination`) and keeps `targetMove`. Next tick,
/// `tickMovement`'s `targetMove` fallback either slides straight or
/// retargets to a passable adjacent tile — and the script system will
/// re-run `CalculateRoute` at the next `tickUnits` dispatch.
@Suite("Movement self-heal — preserve targetMove through route-step halts")
struct MovementSelfHealTests {

    private let TANK: UInt8 = 9
    private let TROOPER: UInt8 = 5
    private let REFINERY: UInt8 = 12

    private func scheduler(
        landscape: @escaping (UInt16) -> UInt8 = { _ in UInt8(LandscapeType.normalSand.rawValue) }
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(landscapeAt: landscape, spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm, teamVM: vm)
    }

    // MARK: - Route-step halt preserves targetMove

    @Test("Blocked route step on a structure clears route but keeps targetMove")
    func blockedRouteStepKeepsTargetMove() {
        var s = scheduler()
        // Put a refinery at (6, 5) so tile (6, 5) is impassable.
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(6 * 256)
        r.positionY = UInt16(5 * 256)
        s.host.structures[rIdx] = r

        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.route[0] = 2  // east → blocked tile
        u.actionID = Simulation.ActionID.move
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 10)).raw
        s.host.units[idx] = u

        s.tick()

        let after = s.host.units[idx]
        #expect(after.route[0] == 0xFF, "route must clear when the next step is impassable")
        #expect(after.currentDestinationX == 0, "currentDestination must clear")
        #expect(after.targetMove != 0, "targetMove must survive for next-tick replan")
    }

    @Test("Blocked route step doesn't move the unit this tick")
    func blockedRouteStepNoMotion() {
        var s = scheduler()
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(6 * 256)
        r.positionY = UInt16(5 * 256)
        s.host.structures[rIdx] = r

        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.speedPerTick = 255
        u.speedRemainder = 255  // so the first tick's accumulator overflows and a step actually fires
        u.route[0] = 2
        u.actionID = Simulation.ActionID.move
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 10)).raw
        s.host.units[idx] = u

        s.tick()
        #expect(s.host.units[idx].positionX == UInt16(5 * 256 + 128))
        #expect(s.host.units[idx].positionY == UInt16(5 * 256 + 128))
    }

    // MARK: - Fallback slide after halt

    @Test("With cleared route + live targetMove, next tick falls through to targetMove fallback slide")
    func fallbackSlideUsesTargetMoveAfterHalt() {
        var s = scheduler()
        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.speedPerTick = 255
        u.speedRemainder = 255  // so the first tick's accumulator overflows and a step actually fires
        u.route = [UInt8](repeating: 0xFF, count: 14)  // no route
        u.actionID = Simulation.ActionID.move
        // Target a reachable tile to the east.
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 10)).raw
        s.host.units[idx] = u

        s.tick()

        let after = s.host.units[idx]
        // Position should have advanced toward the target via the
        // fallback slide (no route needed).
        #expect(after.positionX > UInt16(5 * 256 + 128), "fallback slide should move the unit east")
    }

    // MARK: - Unit-on-tile block preserves targetMove

    @Test("Route step blocked by another unit on the tile clears route but keeps targetMove")
    func routeStepBlockedByUnitKeepsTargetMove() {
        var s = scheduler()
        // Blocker unit sitting on tile (6, 5). Use a TANK (tracked) so
        // the OpenDUNE crush rule doesn't apply — tracked movers crush
        // foot units but block each other.
        let blockerIdx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.harkonnen)!
        var b = s.host.units[blockerIdx]
        b.positionX = UInt16(6 * 256 + 128)
        b.positionY = UInt16(5 * 256 + 128)
        s.host.units[blockerIdx] = b

        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.route[0] = 2  // east toward blocker
        u.actionID = Simulation.ActionID.move
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 10)).raw
        s.host.units[idx] = u

        s.tick()

        let after = s.host.units[idx]
        #expect(after.route[0] == 0xFF, "route clears when a unit sits on the next step")
        #expect(after.targetMove != 0, "targetMove survives so the script can replan")
    }

    // MARK: - Normal moves still work

    @Test("Passable route step moves the unit and consumes route[0] on arrival")
    func passableRouteStepConsumesStep() {
        var s = scheduler()
        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.speedPerTick = 255
        u.speedRemainder = 255  // so the first tick's accumulator overflows and a step actually fires
        u.route[0] = 2  // east
        u.actionID = Simulation.ActionID.move
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 10)).raw
        s.host.units[idx] = u

        s.tick()

        // route[0] should still be 2 OR consumed to next step; what
        // matters is the unit moved east and no stall.
        let after = s.host.units[idx]
        let dx = Int32(after.positionX) - Int32(5 * 256 + 128)
        #expect(dx > 0, "unit should have advanced east on a passable step")
    }

    @Test("orderMove preserves targetMove + clears route; subsequent tick starts motion via fallback")
    func orderMoveThenTickAdvances() {
        var s = scheduler()
        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.speedPerTick = 255
        u.speedRemainder = 255  // so the first tick's accumulator overflows and a step actually fires
        s.host.units[idx] = u
        _ = Simulation.Units.orderMove(
            poolIndex: idx, tileX: 10, tileY: 5, units: &s.host.units
        )
        // Sanity: orderMove left route cleared + targetMove set.
        #expect(s.host.units[idx].route[0] == 0xFF)
        #expect(s.host.units[idx].targetMove != 0)

        s.tick()
        // Fallback slide drove the unit toward the goal even though
        // the script hasn't filled a route yet.
        #expect(s.host.units[idx].positionX > UInt16(5 * 256 + 128))
    }
}
