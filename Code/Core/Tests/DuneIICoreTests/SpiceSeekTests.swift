import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester seek-spice — Scheduler.findNearestSpiceTile + idle-harvester auto-move")
struct SpiceSeekTests {

    private let HARVESTER: UInt8 = 16

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

    @Test("findNearestSpiceTile: no spice anywhere → nil")
    func noSpiceReturnsNil() {
        let map = Simulation.SpiceMap()
        let picked = Simulation.Scheduler.findNearestSpiceTile(
            from: (x: 10, y: 10), map: map
        )
        #expect(picked == nil)
    }

    @Test("findNearestSpiceTile: picks the closest thin tile over a far thick one")
    func picksClosestSpiceTile() {
        var map = Simulation.SpiceMap()
        _ = map.apply(delta: +1, at: UInt16(15 * 64 + 15))  // far thin
        _ = map.apply(delta: +1, at: UInt16(15 * 64 + 15))  // far thick
        _ = map.apply(delta: +1, at: UInt16(11 * 64 + 11))  // near thin
        let picked = Simulation.Scheduler.findNearestSpiceTile(
            from: (x: 10, y: 10), map: map
        )
        #expect(picked?.x == 11)
        #expect(picked?.y == 11)
    }

    @Test("Idle HARVEST-action harvester off spice → auto-orderMove to nearest spice")
    func idleHarvesterSeeksSpice() {
        var s = emptyScheduler(rng: { 1 })
        // Seed spice at (25, 25).
        var map = s.host.spiceMap!
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
        u.currentDestinationX = 0
        u.currentDestinationY = 0
        s.host.units[idx] = u

        s.tickHarvesting()
        let expected = Scripting.EncodedIndex.tile(
            packed: UInt16(25 * 64 + 25)
        ).raw
        #expect(s.host.units[idx].targetMove == expected)
        #expect(s.host.units[idx].actionID == Simulation.ActionID.move)
    }

    @Test("Harvester already moving → seek-spice NOT triggered")
    func alreadyMovingSkipsSeek() {
        var s = emptyScheduler(rng: { 1 })
        var map = s.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(25 * 64 + 25))
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
