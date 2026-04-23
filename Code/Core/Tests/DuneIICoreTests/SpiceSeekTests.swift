import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester seek-spice — Scheduler.findSpiceNear + idle-harvester auto-move")
struct SpiceSeekTests {

    private let HARVESTER: UInt8 = 16
    private let fullRect: (originX: Int, originY: Int, width: Int, height: Int) = (0, 0, 64, 64)

    private func emptyScheduler(rng: @escaping () -> UInt8) -> Simulation.Scheduler {
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: Simulation.SpiceMap()
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm, harvestRNG: rng
        )
    }

    @Test("findSpiceNear: no spice anywhere → nil")
    func noSpiceReturnsNil() {
        let map = Simulation.SpiceMap()
        let picked = Simulation.Scheduler.findSpiceNear(
            from: (x: 10, y: 10),
            radius: 20, playableRect: fullRect,
            map: map,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(picked == nil)
    }

    @Test("findSpiceNear: picks the nearest thin tile over a far thin one (thick-preference only within 4)")
    func picksClosestSpiceTile() {
        var map = Simulation.SpiceMap()
        _ = map.apply(delta: +1, at: UInt16(15 * 64 + 15))  // far thin (distance=5)
        _ = map.apply(delta: +1, at: UInt16(11 * 64 + 11))  // near thin (distance=1)
        let picked = Simulation.Scheduler.findSpiceNear(
            from: (x: 10, y: 10),
            radius: 20, playableRect: fullRect,
            map: map,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(picked?.x == 11)
        #expect(picked?.y == 11)
    }

    @Test("findSpiceNear: prefers thick spice within distance 4 even when thin is closer")
    func prefersThickWithinRadius4() {
        var map = Simulation.SpiceMap()
        // Thin at distance 1; thick at distance 3.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 11))  // thin, d=1
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 13))  // thin, then thick at d=3
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 13))  // → thick
        let picked = Simulation.Scheduler.findSpiceNear(
            from: (x: 10, y: 10),
            radius: 20, playableRect: fullRect,
            map: map,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(picked?.x == 13 && picked?.y == 10, "thick within 4 beats thin outside")
    }

    @Test("findSpiceNear: radius clamps out-of-range spice; widening the radius brings it back in")
    func radiusCapClamps() {
        var map = Simulation.SpiceMap()
        // Spice axis-aligned at (30, 10). Tile_GetDistancePacked
        // metric: max(20, 0) + min(20, 0)/2 = 20.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 30))
        let pickedTight = Simulation.Scheduler.findSpiceNear(
            from: (x: 10, y: 10),
            radius: 10, playableRect: fullRect,
            map: map,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(pickedTight == nil, "radius=10 cap must exclude a spice tile 20 away (axis-aligned)")
        let pickedWide = Simulation.Scheduler.findSpiceNear(
            from: (x: 10, y: 10),
            radius: 25, playableRect: fullRect,
            map: map,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(pickedWide?.x == 30 && pickedWide?.y == 10)
    }

    @Test("findSpiceNear: clamps search to playable rect — spice outside the rect is ignored")
    func playableRectGatesResult() {
        var map = Simulation.SpiceMap()
        // Playable rect is (16..47, 16..47). Spice at (5, 5) is outside.
        _ = map.apply(delta: +1, at: UInt16(5 * 64 + 5))
        let mission1Rect: (originX: Int, originY: Int, width: Int, height: Int) = (16, 16, 32, 32)
        let picked = Simulation.Scheduler.findSpiceNear(
            from: (x: 20, y: 20),
            radius: 30, playableRect: mission1Rect,
            map: map,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(picked == nil, "spice at (5,5) is outside playable rect (16..47) — must not be chosen")
    }

    @Test("findSpiceNear: skips spice tiles occupied by a structure")
    func skipsStructureOccupied() {
        var map = Simulation.SpiceMap()
        _ = map.apply(delta: +1, at: UInt16(11 * 64 + 11))
        var structures = Simulation.StructurePool()
        // Place a concrete slab (type 1) on the spice tile via the
        // non-reserved allocator. Direct slot 0 allocation with the
        // slab occupies (11, 11) as the structure's anchor.
        _ = structures.allocate(at: 0, type: 1, houseID: Simulation.House.atreides)
        var s = structures[0]
        s.positionX = UInt16(11 * 256)
        s.positionY = UInt16(11 * 256)
        structures[0] = s
        let picked = Simulation.Scheduler.findSpiceNear(
            from: (x: 10, y: 10),
            radius: 20, playableRect: fullRect,
            map: map,
            structures: structures,
            units: Simulation.UnitPool(),
            excludingUnit: -1
        )
        #expect(picked == nil, "spice beneath a structure is unreachable — skip it")
    }

    @Test("Idle HARVEST-action harvester off spice → auto-orderMove to nearest spice")
    func idleHarvesterSeeksSpice() {
        var s = emptyScheduler(rng: { 1 })
        // Seed spice at (20, 10) — axis-aligned, d=10, comfortably
        // inside the default autoHarvestSpiceSearchRadius (20).
        var map = s.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 20))
        s.host.spiceMap = map
        let idx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        u.inTransport = false
        u.targetMove = 0
        u.route[0] = 0xFF
        u.currentDestinationX = 0
        u.currentDestinationY = 0
        s.host.units[idx] = u

        s.tickHarvesting()
        let expected = Scripting.EncodedIndex.tile(
            packed: UInt16(10 * 64 + 20)
        ).raw
        #expect(s.host.units[idx].targetMove == expected)
        #expect(s.host.units[idx].actionID == Simulation.ActionID.move)
    }

    @Test("Harvester already moving → seek-spice NOT triggered")
    func alreadyMovingSkipsSeek() {
        var s = emptyScheduler(rng: { 1 })
        var map = s.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 20))
        s.host.spiceMap = map
        let idx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.targetMove = Scripting.EncodedIndex.tile(packed: 500).raw  // already moving
        s.host.units[idx] = u

        s.tickHarvesting()
        // Target unchanged — seek-spice didn't override an active move.
        #expect(s.host.units[idx].targetMove == Scripting.EncodedIndex.tile(packed: 500).raw)
    }

    @Test("Harvester on spice tile → seek-spice NOT triggered (harvest pass handles it)")
    func onSpiceSkipsSeek() {
        var s = emptyScheduler(rng: { 1 })
        var map = s.host.spiceMap!
        // Seed spice under the harvester (10, 10) and also elsewhere.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = map.apply(delta: +1, at: UInt16(25 * 64 + 25))
        s.host.spiceMap = map
        let idx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        u.inTransport = false
        u.targetMove = 0
        u.route[0] = 0xFF
        s.host.units[idx] = u

        s.tickHarvesting()
        // No move issued — already on spice, harvest pass picks it up.
        #expect(s.host.units[idx].targetMove == 0)
        // But the harvest pass DID run, so amount >=0 and inTransport
        // flipped true (jitter=1 grants +1; inTransport set).
        #expect(s.host.units[idx].inTransport == true)
    }
}
