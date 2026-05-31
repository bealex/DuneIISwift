import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Palace special-weapon body — `Structure_ActivateSpecial` (`structure.c:822`) fired by the palace cursor in
/// `GameLoop_Structure` when an AI palace's countdown hits zero. Each house's `specialWeapon` differs:
/// Harkonnen/Sardaukar launch a death-hand missile, Atreides/Fremen call 5 Fremen, Ordos/Mercenary deploy a
/// saboteur. A fresh palace starts at `countDown == 0`, so an AI one fires on its first palace tick.
@Suite("Palace special weapon")
struct PalaceTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func addPalace(_ s: inout GameState, house: UInt8) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.palace.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[.palace].o.hitpoints
        s.structures[slot].o.position = Tile32.unpack(Tile32.packXY(x: 32, y: 32))
        s.structures[slot].countDown = 0
        return slot
    }

    private func countUnits(_ s: inout GameState, type: UnitType, house: UInt8? = nil) -> Int {
        var find = PoolFind(houseID: house ?? Pool.houseInvalid, type: UInt16(type.rawValue))
        var n = 0
        while s.unitFind(&find) != nil { n += 1 }
        return n
    }

    @Test("AI Harkonnen palace launches a death-hand missile at the player's structure")
    func missile() {
        var s = GameState(); s.playerHouseID = 1
        _ = s.houseAllocate(index: 0); s.houses[0].flags.insert(.isAIActive); s.houses[0].unitCountMax = 100
        _ = s.houseAllocate(index: 1)
        let palace = addPalace(&s, house: 0)
        let target = s.structureAllocate(index: Pool.structureIndexInvalid,
                                         type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[target].o.houseID = 1   // the player's structure — not allied with the AI
        s.structures[target].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.structureActivateSpecial(palace)
        // The carrier is created then freed; the launched death-hand bullet (also `missileHouse`) remains.
        #expect(countUnits(&sm.state, type: .missileHouse) == 1)
        #expect(sm.state.structures[palace].countDown == HouseInfo[.harkonnen].specialCountDown)
    }

    @Test("AI Atreides palace calls 5 Fremen and re-arms the countdown")
    func fremen() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 1); s.houses[1].flags.insert(.isAIActive)
        _ = s.houseAllocate(index: 3); s.houses[3].unitCountMax = 100   // HOUSE_FREMEN owns the spawned troopers
        let palace = addPalace(&s, house: 1)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.structureActivateSpecial(palace)
        // Up to 5 — the clustered spawns can collide (`Unit_Create` returns nil on an occupied tile, as in
        // OpenDUNE), so the faithful outcome is 5 minus any overlaps.
        let fremen = countUnits(&sm.state, type: .trooper) + countUnits(&sm.state, type: .troopers)
        #expect((4 ... 5).contains(fremen))
        #expect(sm.state.structures[palace].countDown == HouseInfo[.atreides].specialCountDown)
    }

    @Test("AI Ordos palace deploys a saboteur next to the palace")
    func saboteur() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 2); s.houses[2].flags.insert(.isAIActive); s.houses[2].unitCountMax = 100
        let palace = addPalace(&s, house: 2)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.structureActivateSpecial(palace)
        #expect(countUnits(&sm.state, type: .saboteur, house: 2) == 1)
        #expect(sm.state.structures[palace].countDown == HouseInfo[.ordos].specialCountDown)
    }

    @Test("via the loop: an AI palace fires on its first palace tick; a human palace does not")
    func loopFiresAIOnly() {
        var s = GameState(); s.playerHouseID = 1
        _ = s.houseAllocate(index: 0); s.houses[0].flags.insert(.isAIActive); s.houses[0].unitCountMax = 100
        _ = s.houseAllocate(index: 1); s.houses[1].flags = [.used, .human, .isAIActive]
        let ai = addPalace(&s, house: 0)
        let human = addPalace(&s, house: 1)
        let target = s.structureAllocate(index: Pool.structureIndexInvalid,
                                         type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[target].o.houseID = 1
        s.structures[target].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        // Fire only the palace cursor this tick.
        s.timerGame = 20000
        s.structureTick.palace = 0
        s.structureTick.structure = 30000; s.structureTick.script = 30000; s.structureTick.degrade = 30000

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.gameLoopStructure()
        #expect(sm.state.structures[ai].countDown == HouseInfo[.harkonnen].specialCountDown)   // AI fired
        #expect(sm.state.structures[human].countDown == 0)                                     // human did not
    }
}
