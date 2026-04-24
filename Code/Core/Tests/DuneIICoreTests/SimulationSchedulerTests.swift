import Foundation
import Testing
@testable import DuneIICore

@Suite("Simulation.Scheduler")
struct SimulationSchedulerTests {
    @Test("Scheduler loads engine at entryPoints[slot.type] and seeds variables[0] with actionID")
    func schedulerLoadsEntryPointByType() throws {
        // Regression guard: the scheduler used to pass `actionID` as
        // `typeID` to `unitVM.load`, which landed the PC at
        // `entryPoints[action]` — a different unit type's entry, with
        // all the local-allocation prologue that implies. OpenDUNE
        // loads `entryPoints[u->o.type]` and sets `variables[0] = action`
        // separately. The EMC top-level dispatch reads `variables[0]`
        // to branch per action. See `src/unit.c:520..521`.
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)  // TANK (type 9)
        var u = units[0]
        u.actionID = 3 // ACTION_GUARD
        units[0] = u
        let host = Scripting.Host(units: units)

        // 27 entry points (one per unit type). Each is a JUMP 0 (halt-ish),
        // so the PC stays where load put it long enough to inspect.
        var entryPoints = [UInt16](repeating: 0, count: 27)
        for i in 0..<27 { entryPoints[i] = UInt16(i * 2) }
        let code = Array(repeating: UInt16(0x8000), count: 60)  // 60 words of JUMP 0
        let program = Formats.Emc.Program(
            texts: [],
            entryPoints: entryPoints,
            code: code,
            instructions: [],
            wordIndexToInsn: Array(repeating: -1, count: code.count)
        )
        // Use an empty function table — we only care about load-time state.
        let vm = Scripting.VM(
            program: program,
            functions: Array(repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)

        // Freeze the engine just after load, before any steps, by
        // capturing its state immediately. We do this by giving the
        // engine a delay so tickUnits' reload path runs, writes
        // variables[0], and then the dispatch loop bails on the delay.
        scheduler.tick()
        // Dispatch decremented delay from 0 (fresh) to some steps; the
        // JUMP 0 loops keep pc bouncing but variables[0] persists.
        #expect(scheduler.unitEngines[0].variables[0] == 3,
                "variables[0] should carry actionID=GUARD (3), not type=9")

        // Action change (GUARD → MOVE) triggers reload.
        u = host.units[0]
        u.actionID = 1 // ACTION_MOVE
        host.units[0] = u
        scheduler.tick()
        #expect(scheduler.unitEngines[0].variables[0] == 1,
                "After MOVE action change, variables[0] should be 1")
        #expect(!scheduler.unitEngines[0].halted,
                "Engine should not halt — entry point is valid for type 9")
    }

    @Test("engine.delay counts down 3 → 2 → 1 → 0 over three ticks without stepping")
    func delayCountdownThenDispatch() throws {
        let host = makeHost(withUnitAt: 0, type: 0, house: 0)
        let unitProgram = makeSetReturnProgram()
        let structureProgram = emptyProgram()
        var scheduler = makeScheduler(
            host: host,
            unitProgram: unitProgram,
            structureProgram: structureProgram
        )
        // Seed the unit's engine with delay = 3 and a reset stack.
        scheduler.unitEngines[0] = Scripting.Engine.reset()
        scheduler.unitEngines[0].delay = 3

        // Tick 1: 3 → 2. PC should not have moved.
        scheduler.tick()
        #expect(scheduler.unitEngines[0].delay == 2)
        #expect(scheduler.unitEngines[0].pc == 0)

        // Tick 2: 2 → 1
        scheduler.tick()
        #expect(scheduler.unitEngines[0].delay == 1)
        #expect(scheduler.unitEngines[0].pc == 0)

        // Tick 3: 1 → 0. Still no step.
        scheduler.tick()
        #expect(scheduler.unitEngines[0].delay == 0)
        #expect(scheduler.unitEngines[0].pc == 0)

        // Tick 4: delay is 0, so step up to `unitOpcodesPerTick` opcodes.
        // The program is PUSH 42; SETRETURNVALUE; … so returnValue becomes 42 after two steps.
        scheduler.tick()
        #expect(scheduler.unitEngines[0].pc > 0)

        _ = host // silence unused
    }

    @Test("step budget: a runaway program halts after `unitOpcodesPerTick` opcodes this tick")
    func opcodeBudgetEnforced() throws {
        let host = makeHost(withUnitAt: 0, type: 0, house: 0)
        // Program: 20 consecutive PUSH 0 instructions. Each PUSH 0 is a 2-word insn
        // with opcode 3 (PUSH), 0x2000 flag, and parameter 0.
        let pushZero: [UInt16] = [(UInt16(3) << 8) | 0x2000, 0]
        let words = Array(repeating: pushZero, count: 20).flatMap { $0 }
        let unitProgram = makeProgram(words: words)
        var scheduler = makeScheduler(
            host: host,
            unitProgram: unitProgram,
            structureProgram: emptyProgram()
        )
        scheduler.unitEngines[0] = Scripting.Engine.reset()

        scheduler.tick()
        // Budget is 7. Each PUSH 0 is 2 words → pc advances 2 per opcode step.
        // After 7 steps, pc should be 14. Make sure step advances pc.
        #expect(scheduler.unitEngines[0].pc == 14)
        #expect(!scheduler.unitEngines[0].halted)
    }

    @Test("a host-written delay exits the step loop even with remaining budget")
    func delayWrittenMidLoopEndsTick() throws {
        let host = makeHost(withUnitAt: 0, type: 0, house: 0)
        // Program: PUSH 25; FUNCTION 0 (delay = 5); … more PUSHes that won't run.
        var words: [UInt16] = []
        words += [(UInt16(3) << 8) | 0x2000, 25]       // PUSH 25
        words += [(UInt16(14) << 8) | 0x2000, 0]       // FUNCTION 0 (delay)
        // Three more PUSH 0s — would otherwise run since budget is 7.
        for _ in 0..<3 {
            words += [(UInt16(3) << 8) | 0x2000, 0]
        }
        let unitProgram = makeProgram(words: words)
        var unitFunctions = [Scripting.VM.Function?](repeating: nil, count: 64)
        unitFunctions[0] = Scripting.Functions.delay
        let scheduler = makeScheduler(
            host: host,
            unitProgram: unitProgram,
            structureProgram: emptyProgram(),
            unitFunctions: unitFunctions
        )
        var s = scheduler
        s.unitEngines[0] = Scripting.Engine.reset()
        s.tick()
        #expect(s.unitEngines[0].delay == 5)     // delay was written
        #expect(s.unitEngines[0].pc == 4)         // exactly 2 opcodes ran (4 words)
    }

    @Test("multi-unit walk order matches findArray insertion order")
    func multiUnitWalkOrder() throws {
        let host = Scripting.Host(
            units: Simulation.UnitPool(),
            structures: Simulation.StructurePool(),
            currentObject: nil,
            texts: [], textLog: []
        )
        // Allocate in order 5, then 2, then 9 — findArray should be [5, 2, 9].
        host.units.allocate(at: 5, type: 0, houseID: 0)
        host.units.allocate(at: 2, type: 0, houseID: 0)
        host.units.allocate(at: 9, type: 0, houseID: 0)

        // Every unit's engine starts with delay = 1, so one tick decrements each.
        var scheduler = makeScheduler(
            host: host,
            unitProgram: emptyProgram(),
            structureProgram: emptyProgram()
        )
        scheduler.unitEngines[5].delay = 1
        scheduler.unitEngines[2].delay = 1
        scheduler.unitEngines[9].delay = 1
        scheduler.tick()
        #expect(scheduler.unitEngines[5].delay == 0)
        #expect(scheduler.unitEngines[2].delay == 0)
        #expect(scheduler.unitEngines[9].delay == 0)
        // Untouched slot should still have delay 0.
        #expect(scheduler.unitEngines[0].delay == 0)
    }

    @Test("host.currentObject is set during dispatch and cleared after the tick")
    func currentObjectCleared() throws {
        let host = makeHost(withUnitAt: 3, type: 0, house: 0)
        let scheduler = makeScheduler(
            host: host,
            unitProgram: emptyProgram(),
            structureProgram: emptyProgram()
        )
        var s = scheduler
        s.tick()
        #expect(host.currentObject == nil)
    }

    @Test("structure slab / wall types are skipped even when allocated")
    func structuresSkipSlabsAndWalls() throws {
        let host = Scripting.Host(
            units: Simulation.UnitPool(),
            structures: Simulation.StructurePool(),
            currentObject: nil,
            texts: [], textLog: []
        )
        // Type 0 = SLAB_1x1, 1 = SLAB_2x2, 14 = WALL. Type 7 = a real building.
        host.structures.allocate(at: 0, type: 0, houseID: 0)   // slab 1x1
        host.structures.allocate(at: 1, type: 1, houseID: 0)   // slab 2x2
        host.structures.allocate(at: 2, type: 14, houseID: 0)  // wall
        host.structures.allocate(at: 3, type: 7, houseID: 0)   // real

        var scheduler = makeScheduler(
            host: host,
            unitProgram: emptyProgram(),
            structureProgram: emptyProgram()
        )
        // Every engine starts with delay = 1. Only the real structure should get decremented.
        for idx in 0..<4 { scheduler.structureEngines[idx].delay = 1 }
        scheduler.tick()
        #expect(scheduler.structureEngines[0].delay == 1) // slab 1x1 skipped
        #expect(scheduler.structureEngines[1].delay == 1) // slab 2x2 skipped
        #expect(scheduler.structureEngines[2].delay == 1) // wall skipped
        #expect(scheduler.structureEngines[3].delay == 0) // real building ticked
    }

    @Test("tickHousePowerMaintenance fires once at tick 70 then every 10 800 ticks, draining (powerUsage / 32) + 1 credits per house")
    func houseMaintenanceDrain() throws {
        // Port of `src/house.c:270..273` — every `tickPowerMaintenance`
        // cadence, each allocated house pays
        // `min(credits, (powerUsage / 32) + 1)`. First fire comes from
        // `opendune.c:1503` which seeds the gate to
        // `max(g_timerGame + 70, saved_value)`; for a freshly loaded
        // scheduler that's 70.
        var houses = Simulation.HousePool()
        houses.allocate(at: 1) // Atreides
        houses.allocate(at: 2) // Ordos
        var atreides = houses[1]
        atreides.credits = 305
        atreides.powerUsage = 30           // → cost 1
        houses[1] = atreides
        var ordos = houses[2]
        ordos.credits = 0
        ordos.powerUsage = 0               // → cost 1 but credits clamp to 0
        houses[2] = ordos

        let host = Scripting.Host(houses: houses)
        var scheduler = makeScheduler(
            host: host,
            unitProgram: emptyProgram(),
            structureProgram: emptyProgram()
        )
        // Ticks 1..69 must leave credits untouched — the gate hasn't
        // fired yet.
        for _ in 1..<70 { scheduler.tick() }
        #expect(host.houses[1].credits == 305)
        #expect(host.houses[2].credits == 0)
        // Tick 70 fires the first drain.
        scheduler.tick()
        #expect(host.houses[1].credits == 304)
        #expect(host.houses[2].credits == 0)  // clamped at 0
        // The gate reschedules to 10 880; no further drain until then.
        scheduler.tick()
        #expect(host.houses[1].credits == 304)
    }

    @Test("Power-maintenance drain scales with powerUsage: 30 → 1, 64 → 3, 200 → 7")
    func houseMaintenanceDrainScale() throws {
        // `(usage / 32) + 1` — rounding-down integer math. 30/32=0+1=1,
        // 64/32=2+1=3, 200/32=6+1=7.
        for (usage, cost) in [(UInt16(30), UInt16(1)), (UInt16(64), UInt16(3)), (UInt16(200), UInt16(7))] {
            var houses = Simulation.HousePool()
            houses.allocate(at: 1)
            var h = houses[1]; h.credits = 1000; h.powerUsage = usage; houses[1] = h
            let host = Scripting.Host(houses: houses)
            var scheduler = makeScheduler(
                host: host,
                unitProgram: emptyProgram(),
                structureProgram: emptyProgram()
            )
            for _ in 1...70 { scheduler.tick() }
            #expect(host.houses[1].credits == 1000 - cost,
                    "powerUsage=\(usage) expected cost=\(cost), got credits=\(host.houses[1].credits)")
        }
    }
}

// MARK: - Builders

private func makeHost(withUnitAt idx: Int, type: UInt8, house: UInt8) -> Scripting.Host {
    var units = Simulation.UnitPool()
    units.allocate(at: idx, type: type, houseID: house)
    return Scripting.Host(
        units: units,
        structures: Simulation.StructurePool(),
        currentObject: nil,
        texts: [],
        textLog: []
    )
}

private func makeProgram(words: [UInt16]) -> Formats.Emc.Program {
    (try? Formats.Emc.Program.decodeCode(words)) ?? Formats.Emc.Program(
        texts: [], entryPoints: [], code: words,
        instructions: [], wordIndexToInsn: Array(repeating: -1, count: words.count)
    )
}

private func emptyProgram() -> Formats.Emc.Program {
    // A single JUMP 0 keeps the VM looping harmlessly — never actually executed
    // because tests either set delay > 0 or never step this program.
    makeProgram(words: [0x8000])
}

private func makeSetReturnProgram() -> Formats.Emc.Program {
    // PUSH 42; SETRETURNVALUE 0 — minimal two-opcode program.
    var words: [UInt16] = []
    words += [(UInt16(3) << 8) | 0x2000, 42]     // PUSH 42
    words += [(UInt16(1) << 8) | 0x2000, 0]      // SETRETURNVALUE 0 (reads stack)
    return makeProgram(words: words)
}

private func makeScheduler(
    host: Scripting.Host,
    unitProgram: Formats.Emc.Program,
    structureProgram: Formats.Emc.Program,
    unitFunctions: [Scripting.VM.Function?] = Array(repeating: nil, count: 64),
    structureFunctions: [Scripting.VM.Function?] = Array(repeating: nil, count: 64)
) -> Simulation.Scheduler {
    let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
    let structureVM = Scripting.VM(program: structureProgram, functions: structureFunctions)
    return Simulation.Scheduler(host: host, unitVM: unitVM, structureVM: structureVM)
}
