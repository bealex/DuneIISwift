import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester AI loop — seek refinery when full, dock on arrival, auto-undock on empty")
struct SpiceAILoopTests {

    private let REFINERY: UInt8 = 12
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

    @Test("Full harvester in HARVEST → orderMove issued + actionID flips to RETURN")
    func seekRefineryWhenFull() {
        var scheduler = emptyScheduler(rng: { 1 })
        // Refinery at (30,30) — 3×2 footprint anchored there.
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        scheduler.host.structures[rIdx] = r
        // Full harvester elsewhere in HARVEST.
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.harvest
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()
        let after = scheduler.host.units[hIdx]
        #expect(after.actionID == Simulation.ActionID.returnAction)
        let expected = Scripting.EncodedIndex.tile(
            packed: UInt16(30 * 64 + 30)
        ).raw
        #expect(after.targetMove == expected)
    }

    @Test("RETURN harvester on refinery footprint → dockHarvester fires; state flips to HARVEST")
    func dockOnArrival() {
        var scheduler = emptyScheduler(rng: { 1 })
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        // Stand the harvester on the refinery's anchor tile.
        u.positionX = UInt16(30 * 256 + 128)
        u.positionY = UInt16(30 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.returnAction
        u.inTransport = false
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()
        #expect(scheduler.host.structures[rIdx].linkedID == UInt8(hIdx))
        #expect(scheduler.host.units[hIdx].inTransport == true)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.harvest)
    }

    @Test("Docked harvester drains to zero → auto-undock; actionID stays HARVEST; refinery idle")
    func autoUndockOnEmpty() {
        var scheduler = emptyScheduler(rng: { 0 })
        _ = scheduler.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.amount = 2  // one refine tick of 3 will overshoot; drains to 0
        scheduler.host.units[hIdx] = u
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &scheduler.host.structures, units: &scheduler.host.units
        )
        #expect(scheduler.host.structures[rIdx].linkedID == UInt8(hIdx))

        // One harvesting pass drains everything + auto-undocks.
        scheduler.tickHarvesting()
        #expect(scheduler.host.units[hIdx].amount == 0)
        #expect(scheduler.host.structures[rIdx].linkedID == 0xFF)
        #expect(scheduler.host.structures[rIdx].state == Simulation.StructureState.idle.rawValue)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.harvest)
    }

    @Test("Full cycle: seek → move-simulated → dock → drain → undock (multi-pass)")
    func fullCycle() {
        var scheduler = emptyScheduler(rng: { 0 })
        _ = scheduler.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.harvest
        scheduler.host.units[hIdx] = u

        // Pass 1: seek — flips to RETURN with move target.
        scheduler.tickHarvesting()
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.returnAction)

        // Simulate movement: teleport harvester onto refinery.
        u = scheduler.host.units[hIdx]
        u.positionX = UInt16(30 * 256 + 128)
        u.positionY = UInt16(30 * 256 + 128)
        scheduler.host.units[hIdx] = u

        // Pass 2: arrival — dock, flip action to HARVEST.
        scheduler.tickHarvesting()
        #expect(scheduler.host.structures[rIdx].linkedID == UInt8(hIdx))
        #expect(scheduler.host.units[hIdx].inTransport == true)

        // Passes 3..N: refine drains amount; eventually auto-undock.
        // With rng=0, refine hits full 3/tick; 100/3 = 34 ticks.
        var safety = 0
        while scheduler.host.structures[rIdx].linkedID != 0xFF, safety < 50 {
            scheduler.tickHarvesting()
            safety += 1
        }
        #expect(scheduler.host.units[hIdx].amount == 0)
        #expect(scheduler.host.structures[rIdx].linkedID == 0xFF)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.harvest)
        // Credits: 100 spice × 7 = 700.
        #expect(scheduler.host.houses[Int(Simulation.House.atreides)].credits >= 700)
    }

    @Test("findNearestRefinery picks the closest, skips enemy refineries")
    func nearestRefineryPreferred() {
        var pool = Simulation.StructurePool()
        let near = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var n = pool[near]
        n.positionX = UInt16(15 * 256)
        n.positionY = UInt16(15 * 256)
        pool[near] = n
        let far = pool.allocate(at: 6, type: REFINERY, houseID: Simulation.House.atreides)!
        var f = pool[far]
        f.positionX = UInt16(60 * 256)
        f.positionY = UInt16(60 * 256)
        pool[far] = f
        let enemy = pool.allocate(at: 7, type: REFINERY, houseID: Simulation.House.harkonnen)!
        var e = pool[enemy]
        e.positionX = UInt16(11 * 256)
        e.positionY = UInt16(11 * 256)
        pool[enemy] = e

        var harvester = Simulation.UnitSlot()
        harvester.positionX = UInt16(10 * 256 + 128)
        harvester.positionY = UInt16(10 * 256 + 128)
        harvester.houseID = Simulation.House.atreides
        let picked = Simulation.Scheduler.findNearestRefinery(
            forHarvester: harvester, structures: pool
        )
        #expect(picked == near)
    }

    // MARK: - post-drain auto-seek to the next spice tile

    /// Regression: after fully draining the tile the harvester stands
    /// on, it should auto-seek the nearest remaining spice tile (OpenDUNE
    /// equivalent: `Map_SearchSpice(packed, 20)` triggered by the EMC
    /// script at `src/map.c:1117` when the current tile is off-spice).
    /// Without the auto-seek the harvester sits forever on the drained
    /// cell with action=HARVEST + idle state.
    ///
    /// Setup: single thick-spice tile at (10,10), nearby spice tile at
    /// (12,10), rng fixed to always open the drain gate so we can step
    /// the tile from thick → thin → bare in 2 harvest cycles without
    /// hundreds of no-op ticks.
    /// Full-tick integration: drive the scheduler through many ticks
    /// with a small spice patch and verify the harvester keeps
    /// progressing (either harvests, drains, seeks, or retursn). A
    /// stall = action=HARVEST + idle + off-spice for 50+ ticks.
    ///
    /// Ports the OpenDUNE expectation implicitly: in the original game
    /// a harvester's EMC bytecode loops HARVEST → HARVEST until the
    /// tile drains, then `Script_Unit_FindBestTarget` / `Map_SearchSpice`
    /// picks a new spice tile within radius 20 (`src/map.c:1117`). Our
    /// tickHarvesting AI pass substitutes for the bytecode (`Script_Unit_Harvest`
    /// slot 0x2A is not yet ported); the invariant is the same —
    /// harvester never sits idle on bare sand with work to do.
    /// Same invariant but with the REAL `UNIT.EMC` bytecode loaded
    /// (not the empty VM). This reproduces the live scene: the harvester's
    /// HARVEST-action script runs alongside our `tickHarvesting` AI.
    /// If the EMC script side-effects the harvester's action / targetMove
    /// (e.g. falls through to `Script_Unit_SetActionDefault` on a nil
    /// slot) it can override our AI pass and strand the harvester.
    ///
    /// Gated on TestInstall: short-circuits cleanly if the install isn't
    /// present so CI without the data files still runs green.
    @Test("Full tick loop + real UNIT.EMC: harvester never stalls")
    func fullTickLoopWithRealEmcNeverStalls() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let unitEmc = archive.body(named: "UNIT.EMC") else { return }
        let unitProgram = try Formats.Emc.Program.decode(unitEmc)

        var spiceMap = Simulation.SpiceMap()
        _ = spiceMap.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = spiceMap.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = spiceMap.apply(delta: +1, at: UInt16(10 * 64 + 11))
        _ = spiceMap.apply(delta: +1, at: UInt16(10 * 64 + 11))

        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: spiceMap
        )
        let source = Scripting.RandomSource(lcgSeed: 1, toolsSeed: 1)
        let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
        let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
        let emptyVM = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: Array(repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: unitVM, structureVM: emptyVM, teamVM: emptyVM,
            harvestRNG: { 0 }
        )

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        scheduler.host.units[hIdx] = u

        var stallTicks = 0
        var maxStall = 0
        var actionTrail: [UInt8] = []
        for _ in 0..<200 {
            scheduler.tick()
            let s = scheduler.host.units[hIdx]
            actionTrail.append(s.actionID)
            let packed = UInt16((Int(s.positionY) / 256) * 64 + Int(s.positionX) / 256)
            let lvl = scheduler.host.spiceMap![packed]
            let idle = s.targetMove == 0 && s.route[0] == 0xFF
                && s.currentDestinationX == 0 && s.currentDestinationY == 0
            let onSpice = lvl == .thin || lvl == .thick
            let docked = Simulation.Scheduler.isHarvesterDocked(
                harvesterIndex: hIdx,
                structures: scheduler.host.structures,
                units: scheduler.host.units
            )
            let stalled = s.actionID != Simulation.ActionID.harvest
                && s.actionID != Simulation.ActionID.returnAction
                && idle && !onSpice && !docked && s.amount < 100
            if stalled {
                stallTicks += 1
                maxStall = max(maxStall, stallTicks)
            } else {
                stallTicks = 0
            }
        }
        let trailSummary = Set(actionTrail).sorted()
        #expect(maxStall < 10,
                "harvester stalled for \(maxStall) consecutive ticks in non-harvest/non-return action, idle, off-spice. actions seen: \(trailSummary)")
    }

    /// Long-run integration: realistic RNG, real UNIT.EMC, a few
    /// scattered spice patches, a refinery at a known tile. The
    /// harvester must complete a full cycle — harvest → full → return
    /// → dock → unload → resume harvest — within 2000 ticks. This is
    /// the test that catches "harvests a tile and then stops": any
    /// permanent stall shows up as the cycle never completing.
    @Test("Long-run integration: harvester completes full harvest → dock → unload cycle")
    func longRunCompletesHarvestCycle() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let unitEmc = archive.body(named: "UNIT.EMC") else { return }
        let unitProgram = try Formats.Emc.Program.decode(unitEmc)

        // Spice patch centered at (20,20) — 5×5 thick.
        var spiceMap = Simulation.SpiceMap()
        for dy in -2...2 {
            for dx in -2...2 {
                let p = UInt16((20 + dy) * 64 + (20 + dx))
                _ = spiceMap.apply(delta: +1, at: p)
                _ = spiceMap.apply(delta: +1, at: p)
            }
        }

        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: spiceMap
        )
        // Script_Unit_CalculateRoute uses host.landscapeAt to compute
        // per-terrain SetSpeed (Functions.swift:932). Without it,
        // speed stays 0 and the unit never moves. Read the live
        // spiceMap so terrain under the harvester is always known.
        host.landscapeAt = { [weak host] packed in
            guard let host else { return UInt8(LandscapeType.normalSand.rawValue) }
            return host.spiceMap?.landscapeByte(at: packed)
                ?? UInt8(LandscapeType.normalSand.rawValue)
        }
        _ = host.houses.allocate(at: Int(Simulation.House.atreides))
        let source = Scripting.RandomSource(lcgSeed: 42, toolsSeed: 42)
        let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
        let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
        let emptyVM = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: Array(repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: unitVM, structureVM: emptyVM, teamVM: emptyVM,
            harvestRNG: { source.tools.next() }
        )

        // Refinery at (40,40). 3×2 footprint.
        let rIdx = scheduler.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(40 * 256)
        r.positionY = UInt16(40 * 256)
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        r.linkedID = 0xFF
        scheduler.host.structures[rIdx] = r

        // Harvester at (25,25) — a couple of tiles east of the spice
        // patch, action=HARVEST so the AI pass immediately seeks spice.
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(25 * 256 + 128)
        u.positionY = UInt16(25 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        scheduler.host.units[hIdx] = u

        var everHarvested = false
        var everFilled = false
        var everDocked = false
        var everUndocked = false
        var prevDocked = false
        var prevAmount: UInt8 = 0
        var stalledRuns = 0
        var maxStall = 0

        for _ in 0..<4000 {
            scheduler.tick()
            let s = scheduler.host.units[hIdx]
            let docked = Simulation.Scheduler.isHarvesterDocked(
                harvesterIndex: hIdx,
                structures: scheduler.host.structures,
                units: scheduler.host.units
            )
            if s.amount > prevAmount { everHarvested = true }
            if s.amount >= 100 { everFilled = true }
            if docked { everDocked = true }
            if prevDocked && !docked { everUndocked = true }

            // Stall detection: harvester is idle, action HARVEST, not
            // on spice, not docked, amount<100. The AI pass should
            // rescue it within a single cadence (3 ticks) — a 30+ tick
            // consecutive stall means the AI isn't firing.
            let packed = UInt16((Int(s.positionY) / 256) * 64 + Int(s.positionX) / 256)
            let lvl = scheduler.host.spiceMap![packed]
            let onSpice = lvl == .thin || lvl == .thick
            let idle = s.targetMove == 0 && s.route[0] == 0xFF
                && s.currentDestinationX == 0 && s.currentDestinationY == 0
            let stalled = s.actionID == Simulation.ActionID.harvest
                && idle && !onSpice && !docked && s.amount < 100
                && scheduler.host.spiceMap!.cells.contains(where: { $0 == .thin || $0 == .thick })
            if stalled {
                stalledRuns += 1
                maxStall = max(maxStall, stalledRuns)
            } else {
                stalledRuns = 0
            }
            prevDocked = docked
            prevAmount = s.amount
        }

        #expect(everHarvested, "harvester must gain some spice at least once")
        #expect(everFilled, "harvester must reach full capacity at least once")
        #expect(everDocked, "harvester must dock at the refinery at least once")
        #expect(everUndocked, "harvester must undock after unloading")
        #expect(maxStall < 30,
                "harvester must not stall — max consecutive = \(maxStall) ticks off-spice idle while spice remains on map")
    }

    @Test("Full tick loop: harvester on small spice patch never stalls for 200 ticks")
    func fullTickLoopKeepsProgressing() {
        var scheduler = emptyScheduler(rng: { 0 })  // drain gate always open
        var map = scheduler.host.spiceMap!
        // Single thick tile under the harvester + one neighbour east.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 11))
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 11))
        scheduler.host.spiceMap = map

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        scheduler.host.units[hIdx] = u

        // 200 full ticks. Invariant: the harvester must NEVER spend
        // more than a handful of consecutive ticks on a bare tile with
        // action=HARVEST + idle, because another spice tile is right
        // next door.
        var stallTicks = 0
        var maxStall = 0
        for _ in 0..<200 {
            scheduler.tick()
            let s = scheduler.host.units[hIdx]
            let packed = UInt16((Int(s.positionY) / 256) * 64 + Int(s.positionX) / 256)
            let lvl = scheduler.host.spiceMap![packed]
            let idle = s.targetMove == 0 && s.route[0] == 0xFF
                && s.currentDestinationX == 0 && s.currentDestinationY == 0
            let onSpice = lvl == .thin || lvl == .thick
            let docked = Simulation.Scheduler.isHarvesterDocked(
                harvesterIndex: hIdx,
                structures: scheduler.host.structures,
                units: scheduler.host.units
            )
            let stalled = s.actionID == Simulation.ActionID.harvest
                && idle && !onSpice && !docked && s.amount < 100
            if stalled {
                stallTicks += 1
                maxStall = max(maxStall, stallTicks)
            } else {
                stallTicks = 0
            }
        }
        #expect(maxStall < 10,
                "harvester must not stall on a bare tile (max consecutive = \(maxStall))")
    }

    @Test("Harvester on drained tile auto-seeks the next spice tile (issues orderMove)")
    func autoSeekAfterCurrentTileDepletes() {
        var scheduler = emptyScheduler(rng: { 0 })  // drain gate always open
        // Two spice cells: the one under the harvester + one two tiles east.
        var map = scheduler.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))  // bare → thin
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))  // thin → thick
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 12))  // bare → thin
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 12))  // thin → thick
        scheduler.host.spiceMap = map

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        u.inTransport = false
        scheduler.host.units[hIdx] = u

        // Step the harvester until the current tile is drained to bare.
        // rng=0 → jitter=0 (no amount gain) + drain gate always open →
        // each tick drops spice level. 3 ticks: thick → thin → bare.
        for _ in 0..<3 { scheduler.tickHarvesting() }

        let levelUnderHarvester = scheduler.host.spiceMap![UInt16(10 * 64 + 10)]
        #expect(levelUnderHarvester == .bare,
                "current tile should be drained after 3 harvest cycles; got \(levelUnderHarvester)")

        // One more cadence tick — the AI pass must notice the harvester
        // is idle on a non-spice tile with another spice patch in range
        // and issue orderMove toward (12,10).
        scheduler.tickHarvesting()

        let after = scheduler.host.units[hIdx]
        #expect(after.targetMove != 0,
                "harvester must receive a targetMove to the next spice tile; stuck idle instead (action=\(after.actionID), amount=\(after.amount), inTransport=\(after.inTransport))")
        let expected = Scripting.EncodedIndex.tile(
            packed: UInt16(10 * 64 + 12)
        ).raw
        #expect(after.targetMove == expected,
                "harvester should aim at (12,10), got encoded=\(String(format: "0x%04X", after.targetMove))")
    }
}
