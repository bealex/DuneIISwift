import Foundation
import Testing
@testable import DuneIICore

@Suite("Team AI — TeamPool + team script slots 0x01/0x02/0x06/0x08/0x09/0x0C/0x0D")
struct TeamAITests {

    // MARK: TeamPool

    @Test("TeamPool.allocate fills first-requested slot and rejects duplicates")
    func poolAllocate() {
        var pool = Simulation.TeamPool()
        let first = pool.allocate(
            at: 0, houseID: 0, action: .kamikaze,
            movementType: 1, minMembers: 2, maxMembers: 4
        )
        #expect(first == 0)
        #expect(pool.slots[0].isUsed)
        #expect(pool.slots[0].action == UInt16(Simulation.TeamAction.kamikaze.rawValue))
        #expect(pool.slots[0].actionStart == UInt16(Simulation.TeamAction.kamikaze.rawValue))
        let dup = pool.allocate(
            at: 0, houseID: 0, action: .guard_,
            movementType: 1, minMembers: 1, maxMembers: 2
        )
        #expect(dup == nil)
    }

    @Test("TeamPool.free removes from findArray but survives a second free")
    func poolFree() {
        var pool = Simulation.TeamPool()
        _ = pool.allocate(at: 5, houseID: 0, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3)
        #expect(pool.findArray == [5])
        pool.free(at: 5)
        #expect(pool.findArray == [])
        pool.free(at: 5) // second free is a no-op
        #expect(pool.findArray == [])
    }

    // MARK: slot 0x02 GetMembers

    @Test("slot 0x02 GetMembers returns the team's member count")
    func slot02GetMembers() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 3, houseID: 0, action: .kamikaze, movementType: 1, minMembers: 2, maxMembers: 6)
        var t = host.teams[3]
        t.members = 5
        host.teams[3] = t
        host.currentObject = .team(poolIndex: 3)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetMembersTeam(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(engine.returnValue == 5)
    }

    @Test("slot 0x02 GetMembers returns 0 with no current team")
    func slot02NoTeam() throws {
        let host = makeHost()
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetMembersTeam(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
    }

    // MARK: slot 0x0C GetVariable6 + 0x0D GetTarget

    @Test("slots 0x0C / 0x0D read minMembers and target verbatim")
    func slot0CAnd0D() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 7, houseID: 0, action: .normal, movementType: 1, minMembers: 4, maxMembers: 8)
        var t = host.teams[7]
        t.target = 0x4030 // encoded unit ref
        host.teams[7] = t
        host.currentObject = .team(poolIndex: 7)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeGetVariable6Team(host: host)
        fns[1] = Scripting.Functions.makeGetTargetTeam(host: host)
        let vm = makeVM(words: ins(14, 0) + ins(14, 1), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(engine.returnValue == 4)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 0x4030)
    }

    // MARK: slot 0x01 DisplayText

    @Test("slot 0x01 DisplayText skips drawing when the team is the player")
    func slot01SkipsPlayer() throws {
        let host = makeHost()
        host.texts = ["Enemy approaching"]
        _ = host.teams.allocate(at: 0, houseID: 0, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3)
        host.currentObject = .team(poolIndex: 0)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeDisplayTextTeam(host: host)
        let vm = makeVM(words: ins(3, 0) + ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(host.textLog.isEmpty)
    }

    @Test("slot 0x01 DisplayText writes to log for non-player teams")
    func slot01WritesEnemy() throws {
        let host = makeHost()
        host.texts = ["Enemy approaching"]
        _ = host.teams.allocate(at: 0, houseID: 1, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3) // house 1, not player (0)
        host.currentObject = .team(poolIndex: 0)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeDisplayTextTeam(host: host)
        let vm = makeVM(words: ins(3, 0) + ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(host.textLog.count == 1)
        #expect(host.textLog[0].text == "Enemy approaching")
    }

    // MARK: slot 0x08 Load + 0x09 Load2

    @Test("slot 0x08 Load writes peek(1) to action when different")
    func slot08Load() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 0, houseID: 1, action: .normal, movementType: 1, minMembers: 1, maxMembers: 3)
        host.currentObject = .team(poolIndex: 0)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeLoadTeam(host: host)
        let vm = makeVM(words: ins(3, UInt16(Simulation.TeamAction.kamikaze.rawValue)) + ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(host.teams[0].action == UInt16(Simulation.TeamAction.kamikaze.rawValue))
    }

    @Test("slot 0x09 Load2 resets action to actionStart")
    func slot09Load2() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 0, houseID: 1, action: .normal, movementType: 1, minMembers: 1, maxMembers: 3)
        var t = host.teams[0]
        t.action = UInt16(Simulation.TeamAction.kamikaze.rawValue) // changed mid-game
        host.teams[0] = t
        host.currentObject = .team(poolIndex: 0)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeLoad2Team(host: host)
        let vm = makeVM(words: ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(host.teams[0].action == UInt16(Simulation.TeamAction.normal.rawValue))
    }

    // MARK: slot 0x06 FindBestTarget

    @Test("slot 0x06 FindBestTarget locks on the member's best target")
    func slot06FindBestTarget() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 0, houseID: 1, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3)
        // Team member (tank) at (128,128), house 1.
        _ = host.units.allocate(at: 22, type: 9, houseID: 1)
        var member = host.units[22]
        member.positionX = 128; member.positionY = 128
        member.team = 1 // team index 0 + 1
        host.units[22] = member
        // Enemy QUAD at (384, 128).
        _ = host.units.allocate(at: 30, type: 15, houseID: 0)
        var enemy = host.units[30]
        enemy.positionX = 384; enemy.positionY = 128; enemy.seenByHouses = 0xFF
        host.units[30] = enemy
        host.currentObject = .team(poolIndex: 0)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeFindBestTargetTeam(host: host)
        let vm = makeVM(words: ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        let decoded = Scripting.EncodedIndex(raw: engine.returnValue)
        #expect(decoded.kind == .unit)
        #expect(decoded.decoded == 30)
        // Team's target + targetTile are now stamped.
        #expect(host.teams[0].target == Scripting.EncodedIndex.unit(30).raw)
        #expect(host.teams[0].targetTile == 1)
    }

    // MARK: addToTeam / removeFromTeam

    @Test("addToTeam writes unit.team and bumps team.members")
    func addToTeam() {
        let host = makeHost()
        _ = host.teams.allocate(at: 4, houseID: 0, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 5)
        _ = host.units.allocate(at: 30, type: 9, houseID: 0)
        let remaining = Simulation.Units.addToTeam(unitIndex: 30, teamIndex: 4, host: host)
        #expect(host.units[30].team == 5) // index 4 + 1
        #expect(host.teams[4].members == 1)
        #expect(remaining == 4) // 5 - 1
    }

    @Test("removeFromTeam clears unit.team and decrements team.members")
    func removeFromTeam() {
        let host = makeHost()
        _ = host.teams.allocate(at: 4, houseID: 0, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 5)
        _ = host.units.allocate(at: 30, type: 9, houseID: 0)
        _ = Simulation.Units.addToTeam(unitIndex: 30, teamIndex: 4, host: host)
        let remaining = Simulation.Units.removeFromTeam(unitIndex: 30, host: host)
        #expect(host.units[30].team == 0)
        #expect(host.teams[4].members == 0)
        #expect(remaining == 5)
    }

    @Test("removeFromTeam with team == 0 is a no-op")
    func removeFromTeamNoop() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 0)
        #expect(Simulation.Units.removeFromTeam(unitIndex: 30, host: host) == 0)
    }

    // MARK: slot 0x03 AddClosestUnit

    @Test("slot 0x03 AddClosestUnit pulls in the nearest unaligned matching unit")
    func slot03PullsUnaligned() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 0, houseID: 1, action: .guard_, movementType: 1, minMembers: 2, maxMembers: 6)
        var t = host.teams[0]
        t.positionX = 128; t.positionY = 128
        host.teams[0] = t

        // Two byScenario TANKs, one close + one far. TANK is tracked (movementType 1).
        _ = host.units.allocate(at: 22, type: 9, houseID: 1)
        _ = host.units.allocate(at: 23, type: 9, houseID: 1)
        var near = host.units[22]; near.positionX = 384; near.positionY = 128; near.byScenario = true
        host.units[22] = near
        var far = host.units[23]; far.positionX = 5120; far.positionY = 128; far.byScenario = true
        host.units[23] = far

        host.currentObject = .team(poolIndex: 0)
        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeAddClosestUnitTeam(host: host)
        let vm = makeVM(words: ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)

        #expect(host.units[22].team == 1) // team index 0 + 1
        #expect(host.units[23].team == 0)
        #expect(host.teams[0].members == 1)
        // Remaining capacity = 6 - 1 = 5.
        #expect(engine.returnValue == 5)
    }

    @Test("slot 0x03 skips SABOTEUR and mismatched movement types")
    func slot03SkipsIneligible() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 0, houseID: 1, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3)
        // SABOTEUR (skip) + wheeled TRIKE (movementType mismatch) + tracked TANK (eligible).
        _ = host.units.allocate(at: 22, type: 6, houseID: 1)  // SABOTEUR
        _ = host.units.allocate(at: 23, type: 13, houseID: 1) // TRIKE (wheeled)
        _ = host.units.allocate(at: 24, type: 9, houseID: 1)  // TANK (tracked)
        for (idx, x): (Int, UInt16) in [(22, 256), (23, 384), (24, 640)] {
            var u = host.units[idx]; u.byScenario = true
            u.positionX = x; u.positionY = 128
            host.units[idx] = u
        }
        host.currentObject = .team(poolIndex: 0)
        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeAddClosestUnitTeam(host: host)
        let vm = makeVM(words: ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(host.units[22].team == 0)
        #expect(host.units[23].team == 0)
        #expect(host.units[24].team == 1)
    }

    @Test("slot 0x03 returns 0 when team is already full")
    func slot03Full() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 0, houseID: 1, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 1)
        var t = host.teams[0]; t.members = 1
        host.teams[0] = t

        _ = host.units.allocate(at: 22, type: 9, houseID: 1)
        var u = host.units[22]; u.byScenario = true
        host.units[22] = u
        host.currentObject = .team(poolIndex: 0)

        var fns = [Scripting.VM.Function?](repeating: nil, count: 64)
        fns[0] = Scripting.Functions.makeAddClosestUnitTeam(host: host)
        let vm = makeVM(words: ins(14, 0), functions: fns)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
        #expect(host.units[22].team == 0)
    }

    // MARK: scheduler tickTeams

    @Test("Scheduler.tick visits teams in findArray order and sets currentObject per slot")
    func schedulerTickTeams() throws {
        let host = makeHost()
        _ = host.teams.allocate(at: 2, houseID: 1, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3)
        _ = host.teams.allocate(at: 5, houseID: 1, action: .guard_, movementType: 1, minMembers: 1, maxMembers: 3)

        let vm = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: [Scripting.VM.Function?](repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)
        scheduler.teamEngines[2].delay = 1
        scheduler.teamEngines[5].delay = 2
        scheduler.tick()
        #expect(scheduler.teamEngines[2].delay == 0)
        #expect(scheduler.teamEngines[5].delay == 1)
        #expect(host.currentObject == nil)
    }

    // MARK: teamTable factory

    @Test("teamTable wires the landed slots + fills the rest with NoOp")
    func teamTableFactory() throws {
        let host = makeHost()
        let source = Scripting.RandomSource(seed: 0x42)
        let table = Scripting.Functions.teamTable(host: host, source: source)
        // All 64 slots are non-nil since the factory fills unwired slots
        // with `noOperation` so unported opcodes don't halt TEAM.EMC.
        for i in 0..<64 {
            #expect(table[i] != nil, "slot \(i) should be wired or defaulted to NoOp")
        }
    }

    // MARK: Helpers

    private func makeHost() -> Scripting.Host {
        Scripting.Host(
            units: Simulation.UnitPool(),
            structures: Simulation.StructurePool(),
            explosions: Simulation.ExplosionPool(),
            teams: Simulation.TeamPool(),
            playerHouseID: 0
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
