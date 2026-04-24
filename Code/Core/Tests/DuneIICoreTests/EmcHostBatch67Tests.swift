import Foundation
import Testing
@testable import DuneIICore

@Suite("Scripting host batch 6/7 (positions + simple mutators)")
struct EmcHostBatch67Tests {
    // MARK: Batch 6 — position-dependent generics

    @Test("GetDistanceToTile returns Pos32.distance between currentObject and a tile")
    func getDistanceToTile() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        var u = units[0]
        u.positionX = 1000
        u.positionY = 1000
        units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        // Target tile packed x=3, y=5 → pos32 centred at (896, 1408).
        let tileRaw: UInt16 = 0xC000 | (3 << 1) | (5 << 8)
        let expected = Pos32.distance(Pos32(x: 1000, y: 1000), Pos32(x: 896, y: 1408))

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetDistanceToTile(host: host)
        let vm = makeVM(words: ins(3, tileRaw) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == expected)
    }

    @Test("GetDistanceToObject uses edge-tile adjustment for structure targets (Object_GetDistanceToEncoded parity)")
    func getDistanceToObjectStructureEdge() throws {
        // SOLDIER attacker at (7651, 6941). CYARD (type 8, layout
        // s2x2) at anchor (7680, 6400) — stored top-left. For edge-
        // adjusted distance, the attacker is ~NE of centre so the
        // orient8=0 edge is picked (SE corner at packed 1695 =
        // (31, 26), pos (8064, 6784)). Distance = 413 + 157/2 = 491.
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 4, houseID: 1)
        var u = units[0]
        u.positionX = 7651
        u.positionY = 6941
        units[0] = u

        var structures = Simulation.StructurePool()
        structures.allocate(at: 0, type: 8, houseID: 2)
        var s = structures[0]
        s.positionX = 7680
        s.positionY = 6400
        structures[0] = s

        let host = Scripting.Host(
            units: units, structures: structures,
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetDistanceToObject(host: host)
        let structRaw: UInt16 = 0x8000 | 0  // IT_STRUCTURE, index 0
        let vm = makeVM(words: ins(3, structRaw) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 491,
                "GetDistanceToObject must measure to structure edge tile, not raw anchor centre")
    }

    @Test("GetDistanceToTile returns 0xFFFF for an invalid encoded index")
    func getDistanceInvalid() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetDistanceToTile(host: host)
        // Raw 0 → .none → invalid.
        let vm = makeVM(words: ins(3, 0) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 0xFFFF)
    }

    @Test("VoicePlay appends a VoicePlay to host.voiceLog with current position")
    func voicePlayAppends() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        var u = units[0]
        u.positionX = 500
        u.positionY = 200
        units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeVoicePlay(host: host)
        let vm = makeVM(words: ins(3, 42) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
        #expect(host.voiceLog.count == 1)
        #expect(host.voiceLog[0].voiceID == 42)
        #expect(host.voiceLog[0].positionX == 500)
        #expect(host.voiceLog[0].positionY == 200)
    }

    // MARK: Batch 7 — unit mutators

    @Test("SetOrientationUnit seeds target + speed for gradual rotation (tickRotation advances current)")
    func setOrientationSeedsTargetAndSpeed() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetOrientationUnit(host: host)
        let vm = makeVM(words: ins(3, 0x01A0) + ins(14, 0), functions: functions) // 0xA0 = -96
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        // Port of OpenDUNE `Script_Unit_SetOrientation` → `Unit_SetOrientation(rotateInstantly=false)`:
        // writes orientationTarget; seeds orientationSpeed for rotation
        // via tickRotation; leaves orientationCurrent alone this tick.
        #expect(host.units[0].orientationTarget == -96)
        #expect(host.units[0].orientationSpeed != 0)
        #expect(host.units[0].orientationCurrent == 0)
        // Return value is orientationCurrent reinterpret-cast to UInt16.
        #expect(engine.returnValue == UInt16(bitPattern: Int16(0)))
    }

    @Test("SetSpeedUnit on a byScenario unit clamps to 0..255 with no scale")
    func setSpeedByScenario() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        var u = units[0]; u.byScenario = true; units[0] = u
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetSpeedUnit(host: host)
        let vm = makeVM(words: ins(3, 500) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        // setSpeed stores the 0..255 percent input in `movingSpeed`.
        // `speed` is the tile-hop clamp derived from `movingSpeedFactor`.
        // Return value mirrors OpenDUNE `src/script/unit.c:393` — `u->speed`
        // after `Unit_SetSpeed`, not the input percent.
        #expect(host.units[0].movingSpeed == 255)
        #expect(engine.returnValue == UInt16(host.units[0].speed))
    }

    @Test("SetSpeedUnit on a built unit applies the 192/256 down-scale")
    func setSpeedDownScale() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        // byScenario defaults false → not placed by scenario → down-scale.
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetSpeedUnit(host: host)
        let vm = makeVM(words: ins(3, 256) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        // min(256,255)=255; 255*192/256 = 191. movingSpeed holds the
        // percent input post-scale; `speed` is the tile-hop clamp.
        // Return matches OpenDUNE's `u->speed` after setSpeed.
        #expect(host.units[0].movingSpeed == 191)
        #expect(engine.returnValue == UInt16(host.units[0].speed))
    }

    @Test("StopUnit writes speed = 0")
    func stopWritesZero() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        var u = units[0]; u.speed = 128; units[0] = u
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeStopUnit(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(host.units[0].speed == 0)
    }

    @Test("BlinkUnit writes blinkCounter = 32")
    func blinkWrites() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeBlinkUnit(host: host)
        _ = dispatch(functions: functions, words: ins(14, 0))
        #expect(host.units[0].blinkCounter == 32)
    }

    @Test("DieUnit frees the current unit slot")
    func dieFreesSlot() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeDieUnit(host: host)
        _ = dispatch(functions: functions, words: ins(14, 0))
        #expect(!host.units[0].isUsed)
        #expect(host.units.findArray.isEmpty)
    }

    @Test("SetSpriteUnit writes spriteOffset = -(peek(1) & 0xFF)")
    func setSpriteWrites() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetSpriteUnit(host: host)
        _ = dispatch(functions: functions, words: ins(3, 10) + ins(14, 0))
        #expect(host.units[0].spriteOffset == -10)
    }

    @Test("SetTargetUnit writes targetAttack (and targetMove for non-turreted)")
    func setTargetWritesTargetMove() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)  // CARRYALL — hasTurret=false
        units.allocate(at: 1, type: 0, houseID: 1)
        var u0 = units[0]
        u0.positionX = 1000; u0.positionY = 1000
        u0.orientationCurrent = 17  // sentinel; must not change
        units[0] = u0
        var u1 = units[1]; u1.positionX = 2000; u1.positionY = 1000; units[1] = u1
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetTargetUnit(host: host)
        _ = dispatch(functions: functions, words: ins(3, Scripting.EncodedIndex.unit(1).raw) + ins(14, 0))
        let expected = Scripting.EncodedIndex.unit(1).raw
        #expect(host.units[0].targetAttack == expected)
        // Non-turreted: targetMove also set (OpenDUNE
        // `src/script/unit.c:855-858`).
        #expect(host.units[0].targetMove == expected)
        // Body orientation stays at its prior value — OpenDUNE's
        // `Unit_SetOrientation(u, dir, rotateInstantly=false, 0)` writes
        // `orientation[0].target + .speed`, not `.current`; `tickRotation`
        // updates `.current` gradually. We don't track `target/speed` on
        // slots yet (see ParityHarness skip-list), so the correct
        // observable at this layer is "orientationCurrent unchanged".
        #expect(host.units[0].orientationCurrent == 17)
    }

    @Test("SetTargetUnit clears targetAttack for raw=0 / invalid")
    func setTargetClears() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        var u0 = units[0]; u0.targetAttack = 0x4002; units[0] = u0
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetTargetUnit(host: host)
        _ = dispatch(functions: functions, words: ins(3, 0) + ins(14, 0))
        #expect(host.units[0].targetAttack == 0)
    }

    @Test("IsInTransport returns 1 when set, 0 otherwise")
    func isInTransport() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        var u = units[0]; u.inTransport = true; units[0] = u
        let host = makeHost(units: units, current: .unit(poolIndex: 0))
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIsInTransportUnit(host: host)
        let result = dispatch(functions: functions, words: ins(14, 0))
        #expect(result == 1)
    }

    // MARK: Batch 7 — structure mutators

    @Test("DestroyStructure frees the current structure slot")
    func destroyFreesSlot() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 0, type: 5, houseID: 1)
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeDestroyStructure(host: host)
        _ = dispatch(functions: functions, words: ins(14, 0))
        #expect(!host.structures[0].isUsed)
        #expect(host.structures.findArray.isEmpty)
    }

    // MARK: - Function table smoke test

    @Test("unitTable / structureTable expose the expected slot indices")
    func tablesWireSlots() throws {
        let host = Scripting.Host(
            units: .init(), structures: .init(), currentObject: nil,
            texts: [], textLog: [], voiceLog: []
        )
        let source = Scripting.RandomSource(seed: 1)
        let unitTable = Scripting.Functions.unitTable(host: host, source: source)
        // Spot-check the per-category slots that must be wired.
        #expect(unitTable[0x00] != nil)   // GetInfo
        #expect(unitTable[0x01] != nil)   // SetAction
        #expect(unitTable[0x02] != nil)   // DisplayText
        #expect(unitTable[0x03] != nil)   // GetDistanceToTile
        #expect(unitTable[0x10] != nil)   // Delay
        #expect(unitTable[0x17] != nil)   // RandomRange
        #expect(unitTable[0x20] != nil)   // GetAmount
        #expect(unitTable[0x3C] != nil)   // DelayRandom
        #expect(unitTable[0x3E] != nil)   // GetDistanceToObject

        let structureTable = Scripting.Functions.structureTable(host: host, source: source)
        #expect(structureTable[0x00] != nil)   // Delay
        #expect(structureTable[0x04] != nil)   // SetState
        #expect(structureTable[0x05] != nil)   // DisplayText
        #expect(structureTable[0x0D] != nil)   // GetState
        #expect(structureTable[0x17] != nil)   // Destroy

        // Now-ported slots.
        #expect(unitTable[0x08] != nil)   // Fire — slot 0x08
        // Unported slots stay nil.
        #expect(structureTable[0x08] != nil) // Structure_FindTargetUnit
        #expect(structureTable[0x09] != nil) // Structure_RotateTurret
        #expect(structureTable[0x0A] != nil) // Structure_GetDirection
        #expect(structureTable[0x0B] != nil) // Structure_Fire
    }

    // MARK: Helpers

    @Test("SearchSpice (slot 0x29) returns Tools_Index_Encode(packed, IT_TILE) when host.searchSpice finds a tile")
    func searchSpiceReturnsEncodedTile() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 16 /* HARVESTER */, houseID: 1)
        var u = units[0]
        u.positionX = 24 * 256 + 128
        u.positionY = 21 * 256 + 128
        units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        // Wire the search to return packed tile (23, 21) = 21*64 + 23 = 1367.
        let target: UInt16 = 23 + 21 * 64
        host.searchSpice = { _, _, _ in target }

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0x29] = Scripting.Functions.makeSearchSpice(host: host)
        // PUSH radius=3, FUNCTION 0x29.
        let vm = makeVM(words: ins(3, 3) + ins(14, 0x29), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        // OpenDUNE encoding: ((x*2+1) | ((y*2+1) << 7)) | 0xC000.
        // x=23, y=21 → (47 | (43 << 7)) | 0xC000 = 47 | 5504 | 49152 = 54703.
        #expect(engine.returnValue == 54703,
                "expected encoded IT_TILE for (23, 21) = 54703, got \(engine.returnValue)")
    }

    @Test("SearchSpice returns 0 when host.searchSpice is nil (NoOp default)")
    func searchSpiceNilHostHook() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 16, houseID: 1)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        // host.searchSpice is nil by default.
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0x29] = Scripting.Functions.makeSearchSpice(host: host)
        let vm = makeVM(words: ins(3, 5) + ins(14, 0x29), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
    }

    @Test("SearchSpice returns 0 when host.searchSpice returns 0 (no spice found)")
    func searchSpiceReturnsZero() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 16, houseID: 1)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        host.searchSpice = { _, _, _ in 0 }
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0x29] = Scripting.Functions.makeSearchSpice(host: host)
        let vm = makeVM(words: ins(3, 5) + ins(14, 0x29), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
    }

    private func makeHost(units: Simulation.UnitPool, current: Scripting.Host.ObjectRef?) -> Scripting.Host {
        Scripting.Host(
            units: units, structures: .init(),
            currentObject: current, texts: [], textLog: [], voiceLog: []
        )
    }

    @discardableResult
    private func dispatch(functions: [Scripting.VM.Function?], words: [UInt16]) -> UInt16 {
        let vm = makeVM(words: words, functions: functions)
        var engine = Scripting.Engine.reset()
        while true {
            let r = vm.step(&engine)
            if r == .halted || engine.pc >= words.count { break }
        }
        return engine.returnValue
    }

    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }

    private func makeVM(
        words: [UInt16],
        functions: [Scripting.VM.Function?]
    ) -> Scripting.VM {
        let program = (try? Formats.Emc.Program.decodeCode(words)) ?? Formats.Emc.Program.empty
        return Scripting.VM(program: program, functions: functions)
    }
}
