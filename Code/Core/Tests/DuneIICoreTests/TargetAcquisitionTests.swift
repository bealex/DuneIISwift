import Foundation
import Testing
@testable import DuneIICore

@Suite("Target acquisition — priority math + FindBestTarget + script slots")
struct TargetAcquisitionTests {

    // MARK: House.areAllied

    @Test("areAllied: invalid house rejects")
    func areAlliedInvalid() {
        #expect(Simulation.House.areAllied(0xFF, 0, playerHouseID: 0) == false)
        #expect(Simulation.House.areAllied(0, 0xFF, playerHouseID: 0) == false)
    }

    @Test("areAllied: same house always allies")
    func areAlliedSame() {
        #expect(Simulation.House.areAllied(0, 0, playerHouseID: nil))
        #expect(Simulation.House.areAllied(3, 3, playerHouseID: 1))
    }

    @Test("areAllied: Fremen × Atreides is allied; Fremen × other is not")
    func areAlliedFremen() {
        #expect(Simulation.House.areAllied(Simulation.House.fremen, Simulation.House.atreides, playerHouseID: 1))
        #expect(Simulation.House.areAllied(Simulation.House.atreides, Simulation.House.fremen, playerHouseID: 1))
        #expect(Simulation.House.areAllied(Simulation.House.fremen, Simulation.House.harkonnen, playerHouseID: 1) == false)
    }

    @Test("areAllied: all non-player houses ally with each other")
    func areAlliedNonPlayer() {
        // Player = Atreides (1). Harkonnen (0) and Ordos (2) should be allied.
        #expect(Simulation.House.areAllied(0, 2, playerHouseID: 1))
        // But neither with the player.
        #expect(Simulation.House.areAllied(0, 1, playerHouseID: 1) == false)
    }

    @Test("areAllied: nil playerID → strict equality only")
    func areAlliedNilPlayer() {
        #expect(Simulation.House.areAllied(0, 2, playerHouseID: nil) == false)
    }

    // MARK: Pos32.distanceRoundedUp

    @Test("distanceRoundedUp: rounds up with 0x80 offset before >> 8")
    func distanceRoundedUp() {
        // Distance 256 exactly → 1.
        let a = Pos32(x: 128, y: 128)
        let b = Pos32(x: 384, y: 128)
        #expect(Pos32.distance(a, b) == 256)
        #expect(Pos32.distanceRoundedUp(a, b) == 1)

        // Distance 383 (256 + 127) → (383 + 128) >> 8 = 511 >> 8 = 1.
        let c = Pos32(x: 511, y: 128)
        #expect(Pos32.distance(a, c) == 383)
        #expect(Pos32.distanceRoundedUp(a, c) == 1)

        // Distance 512 → 2.
        let d = Pos32(x: 640, y: 128)
        #expect(Pos32.distance(a, d) == 512)
        #expect(Pos32.distanceRoundedUp(a, d) == 2)
    }

    // MARK: targetUnitPriority

    @Test("targetUnitPriority: self and unallocated return 0")
    func priorityUnitSelf() {
        let slot = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: slot)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: slot, target: slot, host: host) == 0)

        var unalloc = makeUnit(index: 1, type: 9, house: 1, x: 128, y: 128, seen: 0xFF)
        unalloc.isAllocated = false
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: slot, target: unalloc, host: host) == 0)
    }

    @Test("targetUnitPriority: unseen target returns 0")
    func priorityUnitUnseen() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let target = makeUnit(index: 1, type: 9, house: 1, x: 384, y: 128, seen: 0)
        let host = hostWith(attackerUnit: attacker, otherUnits: [target], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: attacker, target: target, host: host) == 0)
    }

    @Test("targetUnitPriority: allied target returns 0")
    func priorityUnitAllied() {
        let attacker = makeUnit(index: 0, type: 9, house: 1, x: 128, y: 128, seen: 0xFF)
        let target = makeUnit(index: 1, type: 9, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: attacker, otherUnits: [target], playerHouseID: 1)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: attacker, target: target, host: host) == 0)
    }

    @Test("targetUnitPriority: priority flag off returns 0 (bullet target)")
    func priorityUnitNoPriority() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        // Type 23 = BULLET, priority = false.
        let target = makeUnit(index: 1, type: 23, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: attacker, otherUnits: [target], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: attacker, target: target, host: host) == 0)
    }

    @Test("targetUnitPriority: winger gated by attacker's targetAir")
    func priorityUnitWingerGate() {
        // Attacker TANK (9): targetAir=false. Target ORNITHOPTER (1): winger.
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let orni = makeUnit(index: 1, type: 1, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, otherUnits: [orni], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: tank, target: orni, host: host) == 0)

        // Attacker LAUNCHER (7): targetAir=true → priority > 0.
        let launcher = makeUnit(index: 0, type: 7, house: 0, x: 128, y: 128, seen: 0xFF)
        let host2 = hostWith(attackerUnit: launcher, otherUnits: [orni], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: launcher, target: orni, host: host2) > 0)
    }

    @Test("targetUnitPriority: pins priority arithmetic for TANK vs QUAD")
    func priorityUnitMath() {
        // Attacker TANK (9) at tile (0,0)=(128,128); target QUAD (15) at tile (1,0)=(384,128).
        // QUAD: priorityBuild=60, priorityTarget=60. total = 120.
        // distanceRoundedUp = 1. priority = 120/1 + 1 = 121.
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let quad = makeUnit(index: 1, type: 15, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, otherUnits: [quad], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: tank, target: quad, host: host) == 121)
    }

    @Test("targetUnitPriority: off-map target returns 0")
    func priorityUnitOffMap() {
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let quad = makeUnit(index: 1, type: 15, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, otherUnits: [quad], playerHouseID: 0)
        // Drop the target's tile out of bounds.
        host.isValidPosition = { packed in
            let x = Int(packed & 0x3F), y = Int((packed >> 6) & 0x3F)
            return !(x == 1 && y == 0)
        }
        #expect(Simulation.TargetAcquisition.targetUnitPriority(attacker: tank, target: quad, host: host) == 0)
    }

    // MARK: targetStructurePriority

    @Test("targetStructurePriority: allied returns 0")
    func priorityStructureAllied() {
        let attacker = makeUnit(index: 0, type: 9, house: 1, x: 128, y: 128, seen: 0xFF)
        let s = makeStructure(index: 0, type: 12, house: 1, x: 384, y: 128)
        let host = hostWith(attackerUnit: attacker, otherStructures: [s], playerHouseID: 1)
        #expect(Simulation.TargetAcquisition.targetStructurePriority(attacker: attacker, target: s, host: host) == 0)
    }

    @Test("targetStructurePriority: pins arithmetic for REFINERY vs TANK")
    func priorityStructureMath() {
        // Refinery (12): priorityBuild=0, priorityTarget=300. Sum=300. Distance rounded up = 1.
        // priority = 300 / 1 = 300.
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let refinery = makeStructure(index: 0, type: 12, house: 1, x: 384, y: 128)
        let host = hostWith(attackerUnit: attacker, otherStructures: [refinery], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.targetStructurePriority(attacker: attacker, target: refinery, host: host) == 300)
    }

    // MARK: findBestTargetUnit

    @Test("findBestTargetUnit: empty pool returns nil")
    func findUnitEmpty() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: attacker, playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.findBestTargetUnit(attackerIndex: 0, mode: 0, host: host) == nil)
    }

    @Test("findBestTargetUnit mode 0 picks highest priority ignoring distance")
    func findUnitMode0() {
        // Attacker TANK at tile (0,0). Targets: QUAD far, TROOPERS near.
        // QUAD: 60+60=120 at tile (10,0). distance=10 → priority=12+1=13.
        // TROOPERS (3): 50+50=100 at tile (2,0). distance=2 → priority=50+1=51.
        // TROOPERS wins.
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let quad = makeUnit(index: 1, type: 15, house: 1, x: 2688, y: 128, seen: 0xFF)   // tile 10
        let troopers = makeUnit(index: 2, type: 3, house: 1, x: 640, y: 128, seen: 0xFF) // tile 2
        let host = hostWith(attackerUnit: tank, otherUnits: [quad, troopers], playerHouseID: 0)
        let best = Simulation.TargetAcquisition.findBestTargetUnit(attackerIndex: 0, mode: 0, host: host)
        #expect(best == 2)
    }

    @Test("findBestTargetUnit mode 1 gates by attacker's fireDistance")
    func findUnitMode1() {
        // TANK fireDistance=4 tiles = 1024 pos32. Target at tile 10 = 2688 → out.
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let far = makeUnit(index: 1, type: 15, house: 1, x: 2688, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, otherUnits: [far], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.findBestTargetUnit(attackerIndex: 0, mode: 1, host: host) == nil)

        // Move target inside range (tile 3 = 896 pos32; TANK fireDistance=4*256=1024).
        let near = makeUnit(index: 1, type: 15, house: 1, x: 896, y: 128, seen: 0xFF)
        let host2 = hostWith(attackerUnit: tank, otherUnits: [near], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.findBestTargetUnit(attackerIndex: 0, mode: 1, host: host2) == 1)
    }

    @Test("findBestTargetUnit stamps originEncoded on first call")
    func findUnitStampsOrigin() {
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 384, y: 640, seen: 0xFF) // tile (1, 2)
        let host = hostWith(attackerUnit: tank, playerHouseID: 0)
        #expect(host.units[0].originEncoded == 0)
        _ = Simulation.TargetAcquisition.findBestTargetUnit(attackerIndex: 0, mode: 0, host: host)
        // After stamping: encoded tile (1, 2).
        #expect(host.units[0].originEncoded != 0)
        let encoded = Scripting.EncodedIndex(raw: host.units[0].originEncoded)
        #expect(encoded.kind == .tile)
        // Decoded to packed (1, 2) → y*64+x = 2*64+1 = 129.
        #expect(encoded.decoded == 129)
    }

    // MARK: findBestTargetStructure

    @Test("findBestTargetStructure skips slabs and walls")
    func findStructureSkipsSlabsWalls() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        // Slab 1x1 (type 0) and Wall (type 14) near; Refinery (type 12) far.
        let slab = makeStructure(index: 0, type: 0, house: 1, x: 384, y: 128)
        let wall = makeStructure(index: 1, type: 14, house: 1, x: 640, y: 128)
        let refinery = makeStructure(index: 2, type: 12, house: 1, x: 2688, y: 128)
        let host = hostWith(attackerUnit: attacker, otherStructures: [slab, wall, refinery], playerHouseID: 0)
        let best = Simulation.TargetAcquisition.findBestTargetStructure(attackerIndex: 0, mode: 0, host: host)
        #expect(best == 2)
    }

    @Test("findBestTargetStructure: >= tie-break prefers the later-allocated")
    func findStructureTieBreak() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let first = makeStructure(index: 0, type: 12, house: 1, x: 384, y: 128)
        let second = makeStructure(index: 1, type: 12, house: 1, x: 384, y: 128)
        let host = hostWith(attackerUnit: attacker, otherStructures: [first, second], playerHouseID: 0)
        // Equal priority: findArray walk order 0, 1. `>=` means second wins.
        let best = Simulation.TargetAcquisition.findBestTargetStructure(attackerIndex: 0, mode: 0, host: host)
        #expect(best == 1)
    }

    // MARK: findBestTargetEncoded

    @Test("findBestTargetEncoded mode 4 prefers structure")
    func findEncodedMode4Structure() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let structure = makeStructure(index: 5, type: 12, house: 1, x: 384, y: 128)
        let unit = makeUnit(index: 1, type: 15, house: 1, x: 640, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: attacker, otherUnits: [unit], otherStructures: [structure], playerHouseID: 0)
        let encoded = Simulation.TargetAcquisition.findBestTargetEncoded(attackerIndex: 0, mode: 4, host: host)
        let decoded = Scripting.EncodedIndex(raw: encoded)
        #expect(decoded.kind == .structure)
        #expect(decoded.decoded == 5)
    }

    @Test("findBestTargetEncoded returns 0 when nothing available")
    func findEncodedNone() {
        let attacker = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: attacker, playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.findBestTargetEncoded(attackerIndex: 0, mode: 0, host: host) == 0)
    }

    @Test("findBestTargetEncoded: deviator skips structures")
    func findEncodedDeviatorSkipsStructures() {
        // Attacker DEVIATOR (8). Provide ONLY a structure → should return 0.
        let deviator = makeUnit(index: 0, type: 8, house: 0, x: 128, y: 128, seen: 0xFF)
        let refinery = makeStructure(index: 0, type: 12, house: 1, x: 384, y: 128)
        let host = hostWith(attackerUnit: deviator, otherStructures: [refinery], playerHouseID: 0)
        #expect(Simulation.TargetAcquisition.findBestTargetEncoded(attackerIndex: 0, mode: 0, host: host) == 0)
    }

    // MARK: Script slot 0x1C / 0x1D via the VM

    @Test("slot 0x1C FindBestTarget returns encoded unit index")
    func scriptSlot1CUnit() throws {
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let quad = makeUnit(index: 1, type: 15, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, otherUnits: [quad], playerHouseID: 0)
        host.currentObject = .unit(poolIndex: 0)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeFindBestTargetUnit(host: host)
        // PUSH 0 (mode), FUNCTION 0.
        let vm = makeVM(words: ins(3, 0) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        let decoded = Scripting.EncodedIndex(raw: engine.returnValue)
        #expect(decoded.kind == .unit)
        #expect(decoded.decoded == 1)
    }

    @Test("slot 0x1D GetTargetPriority returns computed score for unit target")
    func scriptSlot1DUnit() throws {
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let quad = makeUnit(index: 1, type: 15, house: 1, x: 384, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, otherUnits: [quad], playerHouseID: 0)
        host.currentObject = .unit(poolIndex: 0)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetTargetPriorityUnit(host: host)
        let encoded = Scripting.EncodedIndex.unit(1).raw
        let vm = makeVM(words: ins(3, encoded) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 121)
    }

    @Test("slot 0x1D GetTargetPriority returns 0 for tile / none")
    func scriptSlot1DInvalid() throws {
        let tank = makeUnit(index: 0, type: 9, house: 0, x: 128, y: 128, seen: 0xFF)
        let host = hostWith(attackerUnit: tank, playerHouseID: 0)
        host.currentObject = .unit(poolIndex: 0)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetTargetPriorityUnit(host: host)
        let vm = makeVM(words: ins(3, 0xC042) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
    }

    // MARK: Helpers

    private func makeUnit(
        index: UInt16, type: UInt8, house: UInt8,
        x: UInt16, y: UInt16, seen: UInt8
    ) -> Simulation.UnitSlot {
        var slot = Simulation.UnitSlot()
        slot.isUsed = true
        slot.isAllocated = true
        slot.index = index
        slot.type = type
        slot.houseID = house
        slot.positionX = x
        slot.positionY = y
        slot.seenByHouses = seen
        return slot
    }

    private func makeStructure(
        index: UInt16, type: UInt8, house: UInt8,
        x: UInt16, y: UInt16
    ) -> Simulation.StructureSlot {
        var slot = Simulation.StructureSlot()
        slot.isUsed = true
        slot.isAllocated = true
        slot.index = index
        slot.type = type
        slot.houseID = house
        slot.positionX = x
        slot.positionY = y
        return slot
    }

    private func hostWith(
        attackerUnit: Simulation.UnitSlot,
        otherUnits: [Simulation.UnitSlot] = [],
        otherStructures: [Simulation.StructureSlot] = [],
        playerHouseID: UInt8? = nil
    ) -> Scripting.Host {
        var units = Simulation.UnitPool()
        units.allocate(at: Int(attackerUnit.index), type: attackerUnit.type, houseID: attackerUnit.houseID)
        units[Int(attackerUnit.index)] = attackerUnit
        for u in otherUnits {
            units.allocate(at: Int(u.index), type: u.type, houseID: u.houseID)
            units[Int(u.index)] = u
        }
        var structures = Simulation.StructurePool()
        for s in otherStructures {
            structures.allocate(at: Int(s.index), type: s.type, houseID: s.houseID)
            structures[Int(s.index)] = s
        }
        return Scripting.Host(
            units: units, structures: structures,
            playerHouseID: playerHouseID
        )
    }

    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }

    private func makeVM(
        words: [UInt16],
        functions: [Scripting.VM.Function?]
    ) -> Scripting.VM {
        let program = (try? Formats.Emc.Program.decodeCode(words)) ?? Formats.Emc.Program(
            texts: [],
            entryPoints: [],
            code: words,
            instructions: [],
            wordIndexToInsn: Array(repeating: -1, count: words.count)
        )
        return Scripting.VM(program: program, functions: functions)
    }
}
