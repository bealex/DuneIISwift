import Foundation
import Testing
@testable import DuneIICore

/// Regression tests for the 2026-04-23 harvester-UX fixes:
///
/// 1. Manually-moved harvester halts on arrival (coherence pin must
///    respect `.stop` — the action `actionsPlayer[3]` that UNIT.EMC's
///    MOVE script writes on arrival). The harvester stays idle and
///    does NOT auto-resume seeking spice.
/// 2. Auto-harvest spice-seek is bounded by `Scheduler.playableRect`
///    and `autoHarvestSpiceSearchRadius` — harvesters don't wander
///    to the far side of the 64×64 grid or outside the scenario's
///    playable box.
/// 3. Full harvester parked in `.stop` still flips to `.returnAction`
///    so the player isn't forced to hand-pilot a loaded harvester
///    back to a refinery.
@Suite("Harvester — manual-halt respects .stop + playable-rect gating")
struct HarvesterManualHaltTests {

    private let HARVESTER: UInt8 = 16

    private func scheduler(
        rect: (originX: Int, originY: Int, width: Int, height: Int) = (0, 0, 64, 64)
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: Simulation.SpiceMap()
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var s = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm, harvestRNG: { 1 }
        )
        s.playableRect = rect
        return s
    }

    private func harvester(
        in s: inout Simulation.Scheduler,
        at tile: (x: Int, y: Int), amount: UInt8 = 0
    ) -> Int {
        let idx = s.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[idx]
        u.positionX = UInt16(tile.x * 256 + 128)
        u.positionY = UInt16(tile.y * 256 + 128)
        u.amount = amount
        u.inTransport = false
        s.host.units[idx] = u
        return idx
    }

    // MARK: - Coherence pin respects .stop

    @Test("Idle harvester in .stop stays idle — pin does NOT flip to .harvest")
    func stopStaysIdle() {
        var s = scheduler()
        // Seed spice within range so seek-spice WOULD fire if the
        // pin overrode .stop.
        var map = s.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(15 * 64 + 15))
        s.host.spiceMap = map

        let idx = harvester(in: &s, at: (10, 10), amount: 0)
        var u = s.host.units[idx]
        u.actionID = Simulation.ActionID.stop
        s.host.units[idx] = u

        s.tickHarvesting()

        // .stop must persist. targetMove stays 0 (no seek-spice).
        #expect(s.host.units[idx].actionID == Simulation.ActionID.stop,
                "pin must respect user-halted .stop (amount=0)")
        #expect(s.host.units[idx].targetMove == 0,
                "no auto-seek while harvester is user-halted")
    }

    @Test("Full harvester in .stop → flips to .returnAction (sim-side override)")
    func stopFullFlipsToReturn() {
        var s = scheduler()
        let idx = harvester(in: &s, at: (10, 10), amount: 100)
        var u = s.host.units[idx]
        u.actionID = Simulation.ActionID.stop
        s.host.units[idx] = u

        s.tickHarvesting()

        #expect(s.host.units[idx].actionID == Simulation.ActionID.returnAction,
                "full harvester in .stop must flip to RETURN so the player doesn't have to hand-pilot")
    }

    @Test("Non-organic bogus action (guard) + idle + empty → flips to .harvest (pin still defends against drift)")
    func bogusActionStillOverridden() {
        var s = scheduler()
        let idx = harvester(in: &s, at: (10, 10), amount: 0)
        var u = s.host.units[idx]
        u.actionID = Simulation.ActionID.guard_   // bogus EMC drift
        s.host.units[idx] = u

        s.tickHarvesting()

        #expect(s.host.units[idx].actionID == Simulation.ActionID.harvest,
                "pin still overrides non-organic drift (guard is not .stop)")
    }

    // MARK: - Playable-rect gating

    @Test("Auto-seek stays inside playableRect — spice outside the rect is ignored")
    func seekRespectsPlayableRect() {
        // Mission-1-ish rect: (16, 16, 32, 32).
        var s = scheduler(rect: (16, 16, 32, 32))
        var map = s.host.spiceMap!
        // Spice at (5, 5) — outside the rect.
        _ = map.apply(delta: +1, at: UInt16(5 * 64 + 5))
        s.host.spiceMap = map
        let idx = harvester(in: &s, at: (20, 20), amount: 0)
        var u = s.host.units[idx]
        u.actionID = Simulation.ActionID.harvest
        s.host.units[idx] = u

        s.tickHarvesting()

        // No spice inside rect → no seek happens.
        #expect(s.host.units[idx].targetMove == 0,
                "auto-seek must not cross playableRect even if spice exists off-rect")
    }

    @Test("Auto-seek is capped by Scheduler.autoHarvestSpiceSearchRadius (no cross-map scan)")
    func seekRespectsRadiusCap() {
        var s = scheduler()
        var map = s.host.spiceMap!
        // Distance from (10,10) to (60, 10) is 50 (axis-aligned) —
        // far beyond the 20-tile cap.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 60))
        s.host.spiceMap = map
        let idx = harvester(in: &s, at: (10, 10), amount: 0)
        var u = s.host.units[idx]
        u.actionID = Simulation.ActionID.harvest
        s.host.units[idx] = u

        s.tickHarvesting()

        #expect(s.host.units[idx].targetMove == 0,
                "spice 50 tiles away must not be picked under the 20-tile auto-harvest cap")
    }
}
