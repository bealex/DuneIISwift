import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// Decision-trace coverage for `Unit_Damage` (`unit.c:1530`) — each branch asserted against the C logic:
/// non-lethal HP drain, lethal death (player-unit unallocate + `ACTION_DIE`), the half-HP smoke on a
/// tracked hull, the infantry→soldier downgrade, and the sandworm half-HP death.
@Suite("Unit_Damage")
struct UnitCombatTests {
    // offsets[typeID] = typeID, so a script load for type T parks the PC at T.
    let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func setup(_ type: UnitType, hp: UInt16, house: UInt8 = 0, player: UInt8 = 0)
        -> (GameState, Int, UnitCombat) {
        var s = GameState(random256Seed: 0x12345)
        s.playerHouseID = player
        _ = s.houseAllocate(index: house)
        s.houses[Int(house)].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(20 * 64 + 20)
        s.units[slot].o.hitpoints = hp
        let combat = UnitCombat(movement: UnitMovement(scriptInfo: info))
        return (s, slot, combat)
    }

    @Test("non-lethal hit drains hitpoints and the unit survives")
    func nonLethal() {
        var (s, slot, combat) = setup(.tank, hp: 200)
        let died = combat.damage(slot: slot, damage: 50, range: 0, in: &s)
        #expect(!died)
        #expect(s.units[slot].o.hitpoints == 150)
        #expect(s.units[slot].o.flags.contains(.allocated))
        #expect(s.units[slot].actionID != UInt8(ActionType.die.rawValue))
    }

    @Test("a lethal hit kills the unit: zero HP, ACTION_DIE, and a player unit is unallocated")
    func lethal() {
        var (s, slot, combat) = setup(.tank, hp: 30, house: 0, player: 0)
        let died = combat.damage(slot: slot, damage: 50, range: 0, in: &s)
        #expect(died)
        #expect(s.units[slot].o.hitpoints == 0)
        #expect(s.units[slot].actionID == UInt8(ActionType.die.rawValue))
        #expect(!s.units[slot].o.flags.contains(.allocated))   // Unit_RemovePlayer cleared it
    }

    @Test("a non-player unit dying is not unallocated by Unit_RemovePlayer")
    func lethalEnemy() {
        var (s, slot, combat) = setup(.tank, hp: 10, house: 1, player: 0)
        let died = combat.damage(slot: slot, damage: 50, range: 0, in: &s)
        #expect(died)
        #expect(s.units[slot].actionID == UInt8(ActionType.die.rawValue))
        #expect(s.units[slot].o.flags.contains(.allocated))    // not the player's → left allocated
    }

    @Test("dropping a tracked hull below half HP starts it smoking")
    func smokeBelowHalf() {
        let full = UnitInfo[.tank].o.hitpoints
        var (s, slot, combat) = setup(.tank, hp: full / 2 + 5)
        let died = combat.damage(slot: slot, damage: 10, range: 0, in: &s)
        #expect(!died)
        #expect(s.units[slot].o.hitpoints < full / 2)
        #expect(s.units[slot].o.flags.contains(.isSmoking))
        #expect(s.units[slot].spriteOffset == 0)
    }

    @Test("infantry damaged below half upgrades to the soldier type with its hitpoints reset")
    func infantryDowngrade() {
        let full = UnitInfo[.infantry].o.hitpoints
        var (s, slot, combat) = setup(.infantry, hp: full / 2 + 1)
        _ = combat.damage(slot: slot, damage: 2, range: 0, in: &s)
        #expect(s.units[slot].o.type == UInt8(UnitType.soldier.rawValue))   // infantry(2) + 2
        #expect(s.units[slot].o.hitpoints == UnitInfo[.soldier].o.hitpoints)
    }

    @Test("a sandworm below half HP is sent to ACTION_DIE")
    func sandwormBelowHalf() {
        let full = UnitInfo[.sandworm].o.hitpoints
        var (s, slot, combat) = setup(.sandworm, hp: full / 2 + 5)
        let died = combat.damage(slot: slot, damage: 10, range: 0, in: &s)
        #expect(!died)                                            // still has HP
        #expect(s.units[slot].actionID == UInt8(ActionType.die.rawValue))
    }
}
