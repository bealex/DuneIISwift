import Foundation
import Testing
@testable import DuneIICore

@Suite("Simulation.UnitInfo + StructureInfo tables")
struct UnitInfoTests {
    @Test("UnitInfo has 27 entries covering every UnitType from OpenDUNE")
    func unitTableSize() {
        #expect(Simulation.UnitInfo.table.count == 27)
    }

    @Test("UnitInfo.lookup returns canonical values for known unit types")
    func unitLookup() {
        // Type 0 = Carryall: 100 HP, winger movement, no turret.
        let carryall = Simulation.UnitInfo.lookup(0)
        #expect(carryall?.hitpoints == 100)
        #expect(carryall?.movementType == .winger)
        #expect(carryall?.hasTurret == false)

        // Type 9 = Tank: 200 HP, tracked, has turret, fires at 4 tiles.
        let tank = Simulation.UnitInfo.lookup(9)
        #expect(tank?.hitpoints == 200)
        #expect(tank?.movementType == .tracked)
        #expect(tank?.hasTurret == true)
        #expect(tank?.fireDistance == 4)

        // Type 16 = Harvester: harvester movement, default action harvest.
        let harvester = Simulation.UnitInfo.lookup(16)
        #expect(harvester?.movementType == .harvester)
        #expect(harvester?.actionsPlayer[0] == Simulation.ActionID.harvest)
        #expect(harvester?.actionAI == Simulation.ActionID.harvest)

        // Type 25 = Sandworm: 1000 HP, slither movement.
        let worm = Simulation.UnitInfo.lookup(25)
        #expect(worm?.hitpoints == 1000)
        #expect(worm?.movementType == .slither)
    }

    @Test("UnitInfo.lookup returns nil for out-of-range indices")
    func unitLookupOutOfRange() {
        #expect(Simulation.UnitInfo.lookup(255) == nil)
        #expect(Simulation.UnitInfo.lookup(27) == nil)
    }

    @Test("Bullets / missiles / sandworm / frigate carry actionAI == ACTION_INVALID")
    func bulletActionAIInvalid() {
        // OpenDUNE `src/table/unitinfo.c:1391..1975`: every `isBullet`
        // row plus SANDWORM + FRIGATE uses `ACTION_INVALID` for
        // `actionAI`. `Unit_SetAction(u, ACTION_INVALID)` early-returns
        // (`src/unit.c:502`), which is how fresh AI-spawned bullets
        // retain the `Unit_Create`-default `ACTION_GUARD`.
        for type: UInt8 in 18...26 {
            let info = Simulation.UnitInfo.lookup(type)
            #expect(info?.actionAI == Simulation.ActionID.invalid,
                    "type=\(type) should have actionAI=INVALID")
        }
    }

    @Test("resolvedInitialAction picks actionsPlayer[3] for the player and falls back to GUARD on INVALID")
    func resolvedInitialActionBranches() {
        let bulletInfo = Simulation.UnitInfo.lookup(23)!  // BULLET: actionAI=INVALID, actionsPlayer[3]=STOP
        // Player house (Atreides). `actionsPlayer[3] = STOP`, non-invalid,
        // so it wins. Matches OpenDUNE's Unit_Create branch taken on a
        // player-spawned bullet.
        let playerHost = Scripting.Host()
        playerHost.playerHouseID = Simulation.House.atreides
        #expect(Simulation.Units.resolvedInitialAction(
            info: bulletInfo, houseID: Simulation.House.atreides, host: playerHost
        ) == Simulation.ActionID.stop)
        // AI-spawned bullet (house != player). `actionAI = INVALID`
        // triggers the `Unit_SetAction` early-return path, so the
        // bullet keeps the `ACTION_GUARD` that Unit_Create wrote
        // before the SetAction call.
        #expect(Simulation.Units.resolvedInitialAction(
            info: bulletInfo, houseID: Simulation.House.harkonnen, host: playerHost
        ) == Simulation.ActionID.guard_)
    }

    @Test("StructureInfo has 19 entries covering every StructureType")
    func structureTableSize() {
        #expect(Simulation.StructureInfo.table.count == 19)
    }

    @Test("StructureInfo.lookup returns canonical values")
    func structureLookup() {
        // Type 8 = Construction Yard: 400 HP, 2x2, 400 credits.
        let cy = Simulation.StructureInfo.lookup(8)
        #expect(cy?.hitpoints == 400)
        #expect(cy?.buildCredits == 400)
        #expect(cy?.layout == .s2x2)
        #expect(cy?.layout.dimensions.0 == 2)
        #expect(cy?.layout.dimensions.1 == 2)

        // Type 2 = Palace: 1000 HP, 3x3, 999 credits.
        let palace = Simulation.StructureInfo.lookup(2)
        #expect(palace?.hitpoints == 1000)
        #expect(palace?.layout == .s3x3)
        #expect(palace?.buildCredits == 999)

        // Type 12 = Refinery: 3x2 footprint.
        let refinery = Simulation.StructureInfo.lookup(12)
        #expect(refinery?.layout == .s3x2)
        #expect(refinery?.layout.dimensions.0 == 3)
        #expect(refinery?.layout.dimensions.1 == 2)
    }

    // MARK: GetInfo subcases that now read UnitInfo

    @Test("GetInfo 0x00 returns hitpoint ratio (255 for full HP)")
    func getInfoHitpointRatio() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0) // Tank, 200 HP max
        var u = units[0]; u.hitpoints = 100; units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetInfoUnit(host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(3, 0x00) + ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        // 100 * 256 / 200 = 128.
        #expect(engine.returnValue == 128)
    }

    @Test("GetInfo 0x02 returns fireDistance << 8")
    func getInfoFireDistance() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0) // Tank, fireDistance = 4
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetInfoUnit(host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(3, 0x02) + ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 4 << 8)
    }

    @Test("GetInfo 0x0F returns byScenario as 0/1")
    func getInfoByScenario() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0) // Carryall
        var u = units[0]; u.byScenario = true; units[0] = u
        units.allocate(at: 1, type: 0, houseID: 0) // Carryall
        // Slot 1 defaults to byScenario=false.
        for (index, want) in [(0, UInt16(1)), (1, UInt16(0))] {
            let host = Scripting.Host(
                units: units, structures: .init(),
                currentObject: .unit(poolIndex: index),
                texts: [], textLog: [], voiceLog: []
            )
            var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
            functions[0] = Scripting.Functions.makeGetInfoUnit(host: host)
            let vm = Scripting.VM(
                program: (try? Formats.Emc.Program.decodeCode(ins(3, 0x0F) + ins(14, 0))) ?? .empty,
                functions: functions
            )
            var engine = Scripting.Engine.reset()
            _ = vm.step(&engine); _ = vm.step(&engine)
            #expect(engine.returnValue == want)
        }
    }

    @Test("GetInfo 0x09 returns movingSpeed; 0x0A returns |o0Target - o0Current|; 0x0C returns fireDelay==0")
    func getInfoSpeedAndTimers() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)
        var u = units[0]
        u.movingSpeed = 200
        u.orientationCurrent = 10
        u.orientationTarget = 40     // diff = 30
        u.fireDelay = 0              // ready
        units[0] = u

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        for (subcase, want) in [(UInt16(0x09), UInt16(200)), (0x0A, 30), (0x0C, 1)] {
            var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
            functions[0] = Scripting.Functions.makeGetInfoUnit(host: host)
            let vm = Scripting.VM(
                program: (try? Formats.Emc.Program.decodeCode(ins(3, subcase) + ins(14, 0))) ?? .empty,
                functions: functions
            )
            var engine = Scripting.Engine.reset()
            _ = vm.step(&engine); _ = vm.step(&engine)
            #expect(engine.returnValue == want, "subcase=0x\(String(subcase, radix: 16))")
        }
        // `fireDelay = 5 → 0x0C == 0` (not ready).
        var u2 = units[0]; u2.fireDelay = 5; units[0] = u2
        let host2 = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetInfoUnit(host: host2)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(3, 0x0C) + ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
    }

    @Test("GetInfo 0x0D returns explodeOnDeath as 0/1")
    func getInfoExplodeOnDeath() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)  // Tank: explodeOnDeath true
        units.allocate(at: 1, type: 0, houseID: 0)  // Carryall: false
        for (index, want) in [(0, UInt16(1)), (1, UInt16(0))] {
            let host = Scripting.Host(
                units: units, structures: .init(),
                currentObject: .unit(poolIndex: index),
                texts: [], textLog: [], voiceLog: []
            )
            var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
            functions[0] = Scripting.Functions.makeGetInfoUnit(host: host)
            let vm = Scripting.VM(
                program: (try? Formats.Emc.Program.decodeCode(ins(3, 0x0D) + ins(14, 0))) ?? .empty,
                functions: functions
            )
            var engine = Scripting.Engine.reset()
            _ = vm.step(&engine); _ = vm.step(&engine)
            #expect(engine.returnValue == want)
        }
    }

    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }
}
