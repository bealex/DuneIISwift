import Foundation
import Testing
@testable import DuneIICore

@Suite("Sandworm priority + ExplosionMultiple + Tile_MoveByRandom")
struct SandwormAndMultiExplosionTests {

    // MARK: Pos32.movedRandomly

    @Test("movedRandomly with distance=0 returns origin unchanged")
    func movedRandomlyZero() {
        let origin = Pos32(x: 1024, y: 1024)
        let res = Pos32.movedRandomly(from: origin, distance: 0, center: false, random: { 0 })
        #expect(res == origin)
    }

    @Test("movedRandomly consumes exactly 2 bytes from the RNG source")
    func movedRandomlyConsumesTwoBytes() {
        var count = 0
        _ = Pos32.movedRandomly(
            from: Pos32(x: 1024, y: 1024),
            distance: 8,
            center: false,
            random: { count += 1; return 128 }
        )
        #expect(count == 2)
    }

    @Test("movedRandomly with pinned RNG produces deterministic output")
    func movedRandomlyPinned() {
        // random = 0 → newDistance = 0 after halving loop; diff terms = 0.
        let res = Pos32.movedRandomly(
            from: Pos32(x: 2048, y: 2048),
            distance: 8, center: false, random: { 0 }
        )
        #expect(res == Pos32(x: 2048, y: 2048))
    }

    // MARK: Sandworm priority

    @Test("sandwormTargetPriority: unallocated target returns 0")
    func sandwormUnalloc() {
        let host = makeHost()
        let attacker = makeUnit(index: 0, type: 25, house: 3, x: 128, y: 128) // SANDWORM
        var target = makeUnit(index: 1, type: 9, house: 0, x: 384, y: 128)
        target.isAllocated = false
        host.units[0] = attacker
        host.units[1] = target
        #expect(Simulation.TargetAcquisition.sandwormTargetPriority(
            attacker: attacker, target: target, host: host
        ) == 0)
    }

    @Test("sandwormTargetPriority: wheeled at close range scores highest")
    func sandwormWheeledScore() {
        let host = makeHost()
        let attacker = makeUnit(index: 0, type: 25, house: 3, x: 128, y: 128)
        let target = makeUnit(index: 1, type: 13, house: 0, x: 384, y: 128) // TRIKE
        host.units.allocate(at: 0, type: 25, houseID: 3)
        host.units.allocate(at: 1, type: 13, houseID: 0)
        host.units[0] = attacker
        host.units[1] = target
        // TRIKE: wheeled, d = 1 (rounded), not moving, not firing.
        // Raw score = 0x1388 = 5000. distance=1 → 5000/1 = 5000. <2 → ×2 = 10000.
        #expect(Simulation.TargetAcquisition.sandwormTargetPriority(
            attacker: attacker, target: target, host: host
        ) == 10000)
    }

    @Test("sandwormTargetPriority: moving target scores ×4")
    func sandwormMovingBonus() {
        let host = makeHost()
        host.units.allocate(at: 0, type: 25, houseID: 3)
        host.units.allocate(at: 1, type: 9, houseID: 0)
        let attacker = makeUnit(index: 0, type: 25, house: 3, x: 128, y: 128)
        var target = makeUnit(index: 1, type: 9, house: 0, x: 384, y: 128) // TANK
        target.speed = 128
        host.units[0] = attacker
        host.units[1] = target
        // TRACKED raw = 0x3E8 = 1000. moving → ×4 = 4000. d=1 → /1. <2 → ×2 = 8000.
        #expect(Simulation.TargetAcquisition.sandwormTargetPriority(
            attacker: attacker, target: target, host: host
        ) == 8000)
    }

    @Test("sandwormTargetPriority: air unit (winger) scores 0")
    func sandwormAirScoresZero() {
        let host = makeHost()
        host.units.allocate(at: 0, type: 25, houseID: 3)
        host.units.allocate(at: 1, type: 0, houseID: 0)
        let attacker = makeUnit(index: 0, type: 25, house: 3, x: 128, y: 128)
        let target = makeUnit(index: 1, type: 0, house: 0, x: 384, y: 128) // CARRYALL
        host.units[0] = attacker
        host.units[1] = target
        #expect(Simulation.TargetAcquisition.sandwormTargetPriority(
            attacker: attacker, target: target, host: host
        ) == 0)
    }

    // MARK: sandwormFindBestTarget

    @Test("sandwormFindBestTarget picks the highest-priority unit")
    func sandwormPicksBest() {
        let host = makeHost()
        host.units.allocate(at: 0, type: 25, houseID: 3)
        host.units.allocate(at: 1, type: 2, houseID: 0) // INFANTRY (foot) — low score
        host.units.allocate(at: 2, type: 13, houseID: 0) // TRIKE (wheeled) — high score
        var attacker = makeUnit(index: 0, type: 25, house: 3, x: 128, y: 128)
        let foot = makeUnit(index: 1, type: 2, house: 0, x: 256, y: 128)
        let trike = makeUnit(index: 2, type: 13, house: 0, x: 512, y: 128)
        host.units[0] = attacker
        host.units[1] = foot
        host.units[2] = trike
        attacker = host.units[0]

        let best = Simulation.TargetAcquisition.sandwormFindBestTarget(
            attackerIndex: 0, host: host
        )
        #expect(best == 2)
    }

    @Test("sandwormFindBestTarget with no viable prey returns nil")
    func sandwormFindsNone() {
        let host = makeHost()
        host.units.allocate(at: 0, type: 25, houseID: 3)
        // Only airborne prey available.
        host.units.allocate(at: 1, type: 0, houseID: 0)
        #expect(Simulation.TargetAcquisition.sandwormFindBestTarget(
            attackerIndex: 0, host: host
        ) == nil)
    }

    // MARK: slot 0x36 via VM

    @Test("slot 0x36 returns encoded unit index of best sandworm target")
    func slot36Integration() throws {
        let host = makeHost()
        host.units.allocate(at: 0, type: 25, houseID: 3)
        host.units.allocate(at: 5, type: 13, houseID: 0)
        host.units[0] = makeUnit(index: 0, type: 25, house: 3, x: 128, y: 128)
        host.units[5] = makeUnit(index: 5, type: 13, house: 0, x: 384, y: 128)
        host.currentObject = .unit(poolIndex: 0)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSandwormGetBestTargetUnit(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        let decoded = Scripting.EncodedIndex(raw: engine.returnValue)
        #expect(decoded.kind == .unit)
        #expect(decoded.decoded == 5)
    }

    // MARK: slot 0x12 via VM

    @Test("slot 0x12 ExplosionMultiple queues 8 DEATH_HAND explosions")
    func slot12Integration() throws {
        let host = makeHost()
        host.units.allocate(at: 11, type: 11, houseID: 0) // DEVASTATOR
        var dev = host.units[11]
        dev.positionX = 2048; dev.positionY = 2048
        host.units[11] = dev
        host.currentObject = .unit(poolIndex: 11)

        let source = Scripting.RandomSource(seed: 0x1234)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeExplosionMultipleUnit(source: source, host: host)
        // PUSH 256 (radius); FUNCTION 0.
        let vm = makeVM(words: ins(3, 256) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)

        let active = host.explosions.slots.filter(\.isActive)
        // 1 central + up to 7 scatter = ≤ 8 active slots. Random drift can
        // land two scatter points on the same tile; `stopAtPosition`
        // then merges them, matching OpenDUNE's behaviour.
        #expect(active.count >= 1 && active.count <= 8)
        // All are DEATH_HAND (type 11).
        #expect(active.allSatisfy { $0.type == Simulation.ExplosionType.deathHand.rawValue })
    }

    // MARK: Helpers

    private func makeHost() -> Scripting.Host {
        Scripting.Host(
            units: Simulation.UnitPool(),
            structures: Simulation.StructurePool(),
            explosions: Simulation.ExplosionPool(),
            playerHouseID: 0
        )
    }

    private func makeUnit(
        index: UInt16, type: UInt8, house: UInt8, x: UInt16, y: UInt16
    ) -> Simulation.UnitSlot {
        var s = Simulation.UnitSlot()
        s.isUsed = true
        s.isAllocated = true
        s.index = index
        s.type = type
        s.houseID = house
        s.positionX = x
        s.positionY = y
        s.hitpoints = 100
        s.seenByHouses = 0xFF
        return s
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
