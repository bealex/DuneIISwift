import Foundation
import Testing
@testable import DuneIICore

/// Regression suite for the end-to-end harvester loop.
///
/// Bug history:
/// - `harvestSpiceStep` is a port of OpenDUNE's `Script_Unit_Harvest`,
///   which sets `inTransport = true` on the very first successful
///   spice pickup (it flags "has cargo", not "currently harvesting").
///   Our `tickHarvesting` used `!inTransport` as an anti-reharvest
///   gate on the harvest pass AND on the three AI branches. Net
///   effect: a harvester ordered onto spice picked up exactly one
///   unit of cargo (amount = 0 → 1), set `inTransport = true`, and
///   then froze — no further harvesting, no seek-refinery, no
///   seek-spice.
///
/// Fix: replace the `!inTransport` gates with an authoritative "is
/// this harvester chain-linked inside any refinery?" check
/// (`Scheduler.isHarvesterDocked`). `inTransport` stays as the
/// OpenDUNE "has cargo" flag.
@Suite("Harvester continuous loop — harvest → full → refinery → refine → back")
struct HarvesterContinuousLoopTests {

    private let REFINERY: UInt8 = 12
    private let HARVESTER: UInt8 = 16

    private func scheduler(
        rng: @escaping () -> UInt8,
        landscape: @escaping (UInt16) -> UInt8 = { _ in UInt8(LandscapeType.normalSand.rawValue) }
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            landscapeAt: landscape,
            spiceMap: Simulation.SpiceMap()
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: rng
        )
    }

    // MARK: - continuous harvest past the first pickup

    @Test("Harvester on thick spice keeps harvesting after the first pickup (inTransport must not gate)")
    func continuousHarvestPastFirstPickup() {
        var s = scheduler(rng: { 1 })  // jitter=1, gate=1 → no drain
        var map = s.host.spiceMap!
        // Saturate the tile — two applies to push bare → thin → thick.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        s.host.spiceMap = map

        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        u.inTransport = false
        s.host.units[hIdx] = u

        // Five harvest ticks on the same thick tile.
        for _ in 0..<5 { s.tickHarvesting() }
        // After the first call `inTransport` flips to true; the bug
        // was that later calls were skipped. Post-fix they should
        // continue picking up at +1 per tick.
        #expect(s.host.units[hIdx].amount >= 2,
                "harvester must keep picking up after the first pickup; amount=\(s.host.units[hIdx].amount)")
        #expect(s.host.units[hIdx].inTransport == true,
                "inTransport is the OpenDUNE `has cargo` flag and must stay true")
    }

    @Test("Full harvester (amount=100) triggers seek-refinery even though inTransport=true")
    func fullHarvesterSeeksRefineryDespiteInTransport() {
        var s = scheduler(rng: { 0 })
        _ = s.host.houses.allocate(at: Int(Simulation.House.atreides))
        // Place a refinery at a safe distance.
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(20 * 256)
        r.positionY = UInt16(20 * 256)
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        s.host.structures[rIdx] = r

        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[hIdx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 100
        u.inTransport = true  // has cargo — seek-refinery must still fire
        s.host.units[hIdx] = u

        s.tickHarvesting()
        let after = s.host.units[hIdx]
        #expect(after.actionID == Simulation.ActionID.returnAction,
                "full harvester must flip to RETURN action; got \(after.actionID)")
        #expect(after.targetMove != 0,
                "full harvester must receive a targetMove toward the refinery")
    }

    @Test("Docked harvester isn't re-harvested (physical dock is the gate, not inTransport)")
    func dockedHarvesterDoesNotReharvest() {
        var s = scheduler(rng: { 1 })  // gate=1 → no drain, +1 per call if it ran
        _ = s.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(10 * 256)
        r.positionY = UInt16(10 * 256)
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        s.host.structures[rIdx] = r

        // Place a thick spice cell under the refinery's anchor too,
        // so harvestSpiceStep would succeed if it ever ran — the test
        // checks that it does NOT because the harvester is docked.
        var map = s.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        s.host.spiceMap = map

        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.amount = 50
        u.actionID = Simulation.ActionID.harvest
        s.host.units[hIdx] = u

        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &s.host.structures, units: &s.host.units
        )
        let amountAtDock = s.host.units[hIdx].amount
        s.tickHarvesting()
        // Amount only changes because refineSpiceStep drained it, not
        // because harvestSpiceStep re-picked up from the tile.
        #expect(s.host.units[hIdx].amount <= amountAtDock,
                "docked harvester must not gain spice from the harvest pass")
    }

    // MARK: - isHarvesterDocked helper

    @Test("isHarvesterDocked true for a chain-head harvester")
    func isDockedHead() {
        var s = scheduler(rng: { 0 })
        _ = s.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = s.host.structures[rIdx]
        r.hitpoints = 450
        s.host.structures[rIdx] = r
        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &s.host.structures, units: &s.host.units
        )
        #expect(Simulation.Scheduler.isHarvesterDocked(
            harvesterIndex: hIdx,
            structures: s.host.structures,
            units: s.host.units
        ) == true)
    }

    @Test("isHarvesterDocked false for a free harvester in HARVEST action with inTransport=true")
    func isDockedFalseWithCargo() {
        var s = scheduler(rng: { 0 })
        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[hIdx]
        u.actionID = Simulation.ActionID.harvest
        u.inTransport = true  // has cargo, still in the field
        u.amount = 50
        s.host.units[hIdx] = u
        #expect(Simulation.Scheduler.isHarvesterDocked(
            harvesterIndex: hIdx,
            structures: s.host.structures,
            units: s.host.units
        ) == false)
    }

    @Test("After dockHarvester → undockHarvester, isHarvesterDocked becomes false again")
    func dockThenUndock() {
        var s = scheduler(rng: { 0 })
        _ = s.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = s.host.structures[rIdx]
        r.hitpoints = 450
        s.host.structures[rIdx] = r
        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &s.host.structures, units: &s.host.units
        )
        #expect(Simulation.Scheduler.isHarvesterDocked(
            harvesterIndex: hIdx,
            structures: s.host.structures,
            units: s.host.units
        ) == true)
        _ = Simulation.Structures.undockHarvester(
            refineryIndex: rIdx, exitTile: (x: 5, y: 5),
            structures: &s.host.structures, units: &s.host.units
        )
        #expect(Simulation.Scheduler.isHarvesterDocked(
            harvesterIndex: hIdx,
            structures: s.host.structures,
            units: s.host.units
        ) == false)
    }

    // MARK: - return-to-refinery docks on adjacency (not only on footprint)

    /// Regression: a full harvester in RETURN action that halts
    /// adjacent to the refinery's 3×2 footprint (pathfinder won't let
    /// it step onto a blocked structure tile) must still dock.
    /// Before the fix the scheduler's dock probe only checked whether
    /// the harvester's own tile was inside the footprint, so the
    /// harvester got stuck one tile outside with action=RETURN forever.
    @Test("RETURN harvester standing adjacent to refinery footprint docks on the next tick")
    func returnActionDocksOnAdjacency() {
        var s = scheduler(rng: { 0 })
        _ = s.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = s.host.structures[rIdx]
        // Footprint covers (20..22, 20..21) for a 3×2 refinery.
        r.positionX = UInt16(20 * 256)
        r.positionY = UInt16(20 * 256)
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        r.linkedID = 0xFF
        s.host.structures[rIdx] = r

        let hIdx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[hIdx]
        // One tile south of the footprint's south edge.
        u.positionX = UInt16(20 * 256 + 128)
        u.positionY = UInt16(22 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.returnAction
        // No active movement — halted next to the refinery.
        u.targetMove = 0
        u.route[0] = 0xFF
        u.currentDestinationX = 0
        u.currentDestinationY = 0
        u.inTransport = true
        s.host.units[hIdx] = u

        s.tickHarvesting()

        #expect(s.host.structures[rIdx].linkedID == UInt8(hIdx),
                "adjacent RETURN harvester must chain into refinery.linkedID")
        #expect(Simulation.Scheduler.isHarvesterDocked(
            harvesterIndex: hIdx,
            structures: s.host.structures,
            units: s.host.units
        ) == true)
        #expect(s.host.units[hIdx].actionID == Simulation.ActionID.harvest,
                "post-dock action flips to HARVEST so the next undock resumes seeking spice")
    }

    @Test("refineryAtOrAdjacent hits the footprint, all 4 neighbours, and no further")
    func refineryAdjacencyLookup() {
        var s = Simulation.StructurePool()
        let rIdx = s.allocate(at: 0, type: REFINERY, houseID: Simulation.House.atreides)!
        var r = s[rIdx]
        r.positionX = UInt16(20 * 256)
        r.positionY = UInt16(20 * 256)
        s[rIdx] = r

        // Footprint tiles (20,20) (21,20) (22,20) (20,21) (21,21) (22,21)
        for (fx, fy) in [(20, 20), (22, 21)] {
            #expect(Simulation.Scheduler.refineryAtOrAdjacent(
                tile: (x: fx, y: fy), houseID: Simulation.House.atreides, structures: s
            ) == rIdx)
        }
        // 4-adjacents to the footprint
        for (nx, ny) in [(19, 20), (23, 20), (20, 19), (21, 22), (22, 22)] {
            #expect(Simulation.Scheduler.refineryAtOrAdjacent(
                tile: (x: nx, y: ny), houseID: Simulation.House.atreides, structures: s
            ) == rIdx,
            "\(nx),\(ny) should be adjacent to refinery footprint")
        }
        // Diagonals and 2-tiles away are not adjacent.
        for (fx, fy) in [(19, 19), (18, 20), (24, 20)] {
            #expect(Simulation.Scheduler.refineryAtOrAdjacent(
                tile: (x: fx, y: fy), houseID: Simulation.House.atreides, structures: s
            ) == nil,
            "\(fx),\(fy) should NOT be adjacent to refinery footprint")
        }
    }
}
