import Foundation
import Testing
@testable import DuneIICore

@Suite("Movement passability — tickMovement halts at impassable tiles")
struct MovementPassabilityTests {

    private let TANK: UInt8 = 9
    private let TRIKE: UInt8 = 13
    private let REFINERY: UInt8 = 12
    private let CARRYALL: UInt8 = 0

    private func scheduler(landscape: @escaping (UInt16) -> UInt8) -> Simulation.Scheduler {
        let host = Scripting.Host(
            landscapeAt: landscape,
            spiceMap: nil
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm, teamVM: vm)
    }

    @Test("Fallback slide into an ENTIRELY_MOUNTAIN tile halts; position unchanged")
    func fallbackSlideHaltsAtMountain() {
        var s = scheduler { _ in UInt8(LandscapeType.entirelyMountain.rawValue) }
        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.speed = 100
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(20 * 64 + 20)).raw
        u.actionID = Simulation.ActionID.move
        s.host.units[idx] = u
        s.tick()
        // Unit shouldn't have moved toward the impassable target — the
        // `isTilePassable` gate refuses every route step.
        #expect(s.host.units[idx].positionX == UInt16(10 * 256 + 128))
        #expect(s.host.units[idx].currentDestinationX == 0)
    }

    @Test("Route step into a structure tile clears route + currentDestination but keeps targetMove for replan")
    func routeStepIntoStructureHalts() {
        var s = scheduler { _ in UInt8(LandscapeType.normalSand.rawValue) }
        // Place a refinery at tile (6, 5).
        let rIdx = s.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(6 * 256)
        r.positionY = UInt16(5 * 256)
        s.host.structures[rIdx] = r

        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)  // at tile (5, 5)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.route[0] = 2  // east → next tile is (6, 5) = structure
        u.actionID = Simulation.ActionID.move
        // Pick a targetMove that's the same tile the (blocked) route
        // would have reached, so the pathfinder-based replan doesn't
        // synthesise a fresh route that bypasses the structure on the
        // very same tick.
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 6)).raw
        s.host.units[idx] = u
        s.tick()
        #expect(s.host.units[idx].currentDestinationX == 0)
        // targetMove is retained so the next tick's replan can rebuild
        // the route once whatever was blocking the way clears.
        #expect(s.host.units[idx].targetMove != 0)
    }

    @Test("Winger (carryall) can fly over mountain — not halted")
    func wingerIgnoresLandscape() {
        var s = scheduler { _ in UInt8(LandscapeType.entirelyMountain.rawValue) }
        let idx = s.host.units.allocateForType(type: CARRYALL, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.speed = 255
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(20 * 64 + 20)).raw
        u.actionID = Simulation.ActionID.move
        s.host.units[idx] = u
        s.tick()
        // Carryall slid toward target (targetMove preserved while in flight).
        #expect(s.host.units[idx].targetMove != 0)
    }

    @Test("Passable sand tile — tank moves normally, no halt")
    func passableSandAllowsStep() {
        var s = scheduler { _ in UInt8(LandscapeType.normalSand.rawValue) }
        let idx = s.host.units.allocateForType(type: TANK, houseID: Simulation.House.atreides)!
        var u = s.host.units[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.speed = 100
        u.route[0] = 2  // east
        u.actionID = Simulation.ActionID.move
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(5 * 64 + 8)).raw
        s.host.units[idx] = u
        s.tick()
        // currentDestination should have been populated from route[0]
        // to point at tile (6, 5) = pos 1664, 1408.
        #expect(s.host.units[idx].currentDestinationX != 0 || s.host.units[idx].positionX != UInt16(5 * 256 + 128))
        #expect(s.host.units[idx].route[0] != 0xFF)  // route not halted
    }

    @Test("Scheduler.isTilePassable: MOUNTAIN blocks vehicles but infantry on foot can climb")
    func isTilePassableByLandscape() {
        let mountain = scheduler { _ in UInt8(LandscapeType.entirelyMountain.rawValue) }
        // Foot-speed on mountain = 64 per OpenDUNE — passable, just slow.
        #expect(mountain.isTilePassable(tileX: 10, tileY: 10, movementType: .foot) == true)
        #expect(mountain.isTilePassable(tileX: 10, tileY: 10, movementType: .tracked) == false)
        #expect(mountain.isTilePassable(tileX: 10, tileY: 10, movementType: .wheeled) == false)
        #expect(mountain.isTilePassable(tileX: 10, tileY: 10, movementType: .harvester) == false)
        // Wingers fly over anything.
        #expect(mountain.isTilePassable(tileX: 10, tileY: 10, movementType: .winger) == true)

        let rock = scheduler { _ in UInt8(LandscapeType.entirelyRock.rawValue) }
        // Rock is passable for all ground units per OpenDUNE — wheeled
        // are merely slowed (speed 112/256), not blocked.
        #expect(rock.isTilePassable(tileX: 10, tileY: 10, movementType: .foot) == true)
        #expect(rock.isTilePassable(tileX: 10, tileY: 10, movementType: .tracked) == true)
        #expect(rock.isTilePassable(tileX: 10, tileY: 10, movementType: .wheeled) == true)
    }

    @Test("Scheduler.isTilePassable: wall blocks all ground types")
    func wallBlocksAll() {
        let wall = scheduler { _ in UInt8(LandscapeType.wall.rawValue) }
        #expect(wall.isTilePassable(tileX: 10, tileY: 10, movementType: .foot) == false)
        #expect(wall.isTilePassable(tileX: 10, tileY: 10, movementType: .tracked) == false)
        #expect(wall.isTilePassable(tileX: 10, tileY: 10, movementType: .wheeled) == false)
    }

    @Test("Scheduler.isTilePassable: off-map tiles fail")
    func offMapImpassable() {
        let s = scheduler { _ in UInt8(LandscapeType.normalSand.rawValue) }
        #expect(s.isTilePassable(tileX: -1, tileY: 0, movementType: .foot) == false)
        #expect(s.isTilePassable(tileX: 64, tileY: 0, movementType: .tracked) == false)
    }
}
