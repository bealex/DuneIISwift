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

    @Test("a death raises the spoken 'unit destroyed' feedback (Sound_Output_Feedback)")
    func deathFeedback() {
        // An enemy unit (early campaign) → the generic "enemy unit destroyed" (13).
        var (s, slot, combat) = setup(.tank, hp: 30, house: 2, player: 0)
        _ = combat.damage(slot: slot, damage: 50, range: 0, in: &s)
        #expect(s.pendingFeedback.contains(13))

        // The player's own unit → its house's announcement (houseID + 14; Harkonnen 0 → 14).
        var (s2, slot2, combat2) = setup(.tank, hp: 30, house: 0, player: 0)
        _ = combat2.damage(slot: slot2, damage: 50, range: 0, in: &s2)
        #expect(s2.pendingFeedback.contains(14))

        // A saboteur uses its own feedback (20).
        var (s3, slot3, combat3) = setup(.saboteur, hp: 10, house: 2, player: 0)
        _ = combat3.damage(slot: slot3, damage: 50, range: 0, in: &s3)
        #expect(s3.pendingFeedback.contains(20))

        // A `noMessageOnDeath` unit (the sandworm) dies silently — no death announcement.
        var (s4, slot4, combat4) = setup(.sandworm, hp: 1000, house: 2, player: 0)
        _ = combat4.damage(slot: slot4, damage: 2000, range: 0, in: &s4)
        #expect(s4.pendingFeedback.isEmpty)
    }

    @Test("a non-player unit dying is not unallocated by Unit_RemovePlayer")
    func lethalEnemy() {
        var (s, slot, combat) = setup(.tank, hp: 10, house: 1, player: 0)
        let died = combat.damage(slot: slot, damage: 50, range: 0, in: &s)
        #expect(died)
        #expect(s.units[slot].actionID == UInt8(ActionType.die.rawValue))
        #expect(s.units[slot].o.flags.contains(.allocated))    // not the player's → left allocated
    }

    // MARK: - The DIE-branch natives (ExplosionSingle 0x0E → Die 0x0F)

    @Test("Script_Unit_Die removes the unit and stops its running script")
    func dieRemoves() {
        var (s, slot, combat) = setup(.tank, hp: 1)
        var engine = s.units[slot].o.script
        engine.scriptPC = 5                                        // a running script
        _ = combat.movement.die(slot: slot, engine: &engine, in: &s)
        #expect(!s.units[slot].o.flags.contains(.used))           // Unit_Remove freed the slot
        #expect(engine.scriptPC == ScriptEngine.scriptNull)       // and the running script stopped
    }

    @Test("Script_Unit_Die: a saboteur leaves a death explosion at its position")
    func saboteurDieExplodes() {
        var (s, slot, combat) = setup(.saboteur, hp: 1)
        let pos = s.units[slot].o.position
        var engine = s.units[slot].o.script
        _ = combat.movement.die(slot: slot, engine: &engine, in: &s)
        #expect(!s.units[slot].o.flags.contains(.used))
        #expect(s.map[Int(pos.packed)].hasExplosion)              // EXPLOSION_SABOTEUR_DEATH started
    }

    @Test("Script_Unit_ExplosionSingle starts an explosion at the unit")
    func explosionSingleStarts() {
        var (s, slot, combat) = setup(.tank, hp: 200)
        let pos = s.units[slot].o.position
        _ = combat.movement.explosionSingle(slot: slot, type: UInt16(ExplosionType.tankExplode.rawValue), in: &s)
        #expect(s.map[Int(pos.packed)].hasExplosion)
        #expect(s.explosions.contains { $0.active })
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

    // MARK: - Unit_Deviate

    @Test("deviate at full probability mind-controls the unit and clears its targets")
    func deviateSucceeds() {
        var (s, slot, combat) = setup(.tank, hp: 200, house: 0, player: 0)
        s.units[slot].targetAttack = 1234
        s.units[slot].targetMove = 5678
        let ok = combat.deviate(slot: slot, probability: 256, houseID: 1, in: &s)   // 256 ⇒ draw always < it
        #expect(ok)
        #expect(s.units[slot].deviated == 120)
        #expect(s.units[slot].deviatedHouse == 1)
        #expect(s.units[slot].targetAttack == 0)
        #expect(s.units[slot].targetMove == 0)
    }

    @Test("an already-deviated unit cannot be deviated again")
    func deviateAlready() {
        var (s, slot, combat) = setup(.tank, hp: 200)
        s.units[slot].deviated = 50
        let ok = combat.deviate(slot: slot, probability: 256, houseID: 1, in: &s)
        #expect(!ok)
        #expect(s.units[slot].deviated == 50)   // unchanged
    }

    @Test("an isNotDeviatable unit is immune")
    func deviateImmune() {
        var (s, slot, combat) = setup(.carryall, hp: 200)   // carryall: isNormalUnit + isNotDeviatable
        let ok = combat.deviate(slot: slot, probability: 256, houseID: 1, in: &s)
        #expect(!ok)
        #expect(s.units[slot].deviated == 0)
    }

    @Test("a probability the RNG draw exceeds leaves the unit undeviated")
    func deviateFails() {
        var (s, slot, combat) = setup(.tank, hp: 200)   // seed 0x12345: first draw > 1
        let ok = combat.deviate(slot: slot, probability: 1, houseID: 1, in: &s)
        #expect(!ok)
        #expect(s.units[slot].deviated == 0)
    }

    // MARK: - Spawning (Unit_Create / Unit_CreateBullet) + Fire

    @Test("unitCreate: a winger spawns placed, allocated, full HP, on-map, at its default action")
    func createWinger() throws {
        var (s, _, combat) = setup(.tank, hp: 200)
        let pos = Tile32.unpack(30 * 64 + 30)
        let c = try #require(combat.unitCreate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.carryall.rawValue),
                                               houseID: 0, position: pos, orientation: 64, in: &s))
        #expect(s.units[c].o.flags.contains(.used))
        #expect(s.units[c].o.flags.contains(.allocated))
        #expect(!s.units[c].o.flags.contains(.isNotOnMap))
        #expect(s.units[c].o.position == pos)
        #expect(s.units[c].o.hitpoints == UnitInfo[.carryall].o.hitpoints)
        #expect(s.units[c].orientation[0].current == 64)
        #expect(s.units[c].actionID == UInt8(UnitInfo[.carryall].o.actionsPlayer[3].rawValue))
    }

    @Test("unitCreate: an off-map position ⇒ isNotOnMap, unplaced")
    func createOffMap() throws {
        var (s, _, combat) = setup(.tank, hp: 200)
        let c = try #require(combat.unitCreate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.carryall.rawValue),
                                               houseID: 0, position: Tile32(x: 0xFFFF, y: 0xFFFF), orientation: 0, in: &s))
        #expect(s.units[c].o.flags.contains(.isNotOnMap))
    }

    @Test("unitCreateBullet (bullet): faces the target, carries the damage, big when damage>15")
    func createBullet() throws {
        var (s, attacker, combat) = setup(.tank, hp: 200)
        let target = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        s.units[target].o.position = Tile32.unpack(20 * 64 + 25)
        let targetEnc = s.indexEncode(s.units[target].o.index, type: .unit)
        let pos = s.units[attacker].o.position

        let b = try #require(combat.unitCreateBullet(position: pos, type: UInt8(UnitType.bullet.rawValue),
                                                     houseID: 0, damage: 25, target: targetEnc, in: &s))
        #expect(s.units[b].o.type == UInt8(UnitType.bullet.rawValue))
        #expect(s.units[b].o.hitpoints == 25)
        #expect(s.units[b].currentDestination == s.indexGetTile(targetEnc))
        #expect(s.units[b].o.flags.contains(.bulletIsBig))   // 25 > 15
        #expect(s.units[b].orientation[0].current == Tile32.direction(from: pos, to: s.indexGetTile(targetEnc)))

        // A small bullet (≤ 15 damage) is not "big".
        let b2 = try #require(combat.unitCreateBullet(position: pos, type: UInt8(UnitType.bullet.rawValue),
                                                      houseID: 0, damage: 10, target: targetEnc, in: &s))
        #expect(!s.units[b2].o.flags.contains(.bulletIsBig))
    }

    @Test("fire: no/invalid attack target ⇒ no shot (0)")
    func fireNoTarget() {
        var (s, slot, combat) = setup(.tank, hp: 200)
        #expect(combat.fire(slot: slot, in: &s) == 0)            // targetAttack 0
        s.units[slot].targetAttack = 0xABCD                      // invalid index
        #expect(combat.fire(slot: slot, in: &s) == 0)
    }

    @Test("fire: a tank shot emits its bulletSound (Voice_PlayAtTile) at the firer's position")
    func fireEmitsSound() {
        var (s, slot, combat) = setup(.tank, hp: 200, house: 0, player: 0)
        _ = s.houseAllocate(index: 1)
        s.houses[1].unitCountMax = 100
        let enemy = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 1)!
        s.units[enemy].o.position = Tile32.unpack(21 * 64 + 20)   // one tile east, inside fire range
        let target = s.indexEncode(s.units[enemy].o.index, type: .unit)
        s.units[slot].targetAttack = target
        let dir = Tile32.direction(from: s.units[slot].o.position, to: s.units[enemy].o.position)
        for level in 0 ..< 2 { s.units[slot].orientation[level].current = dir; s.units[slot].orientation[level].speed = 0 }   // tank has a turret ⇒ aimLevel 1
        s.units[slot].fireDelay = 0
        s.soundEvents.removeAll()

        #expect(combat.fire(slot: slot, in: &s) == 1)
        #expect(s.soundEvents.contains { $0.sound == SoundID(Int(UnitInfo[.tank].bulletSound)) })
        #expect(s.soundEvents.first?.positionX == Int(s.units[slot].o.position.x))
    }

    @Test("mapMakeExplosion: damages units in radius (scaled by distance), spares the far + provokes the enemy")
    func mapMakeExplosion() {
        var (s, origin, combat) = setup(.tank, hp: 200, house: 0, player: 0)   // the firer (house 0)
        _ = s.houseAllocate(index: 2)
        s.houses[2].unitCountMax = 100
        let pos = Tile32.unpack(20 * 64 + 20)

        // An enemy tank on the blast tile (distance 0 ⇒ full hitpoints), GUARD + byScenario.
        let near = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 2)!
        s.units[near].o.position = pos
        s.units[near].o.hitpoints = 200
        s.units[near].actionID = UInt8(ActionType.guard_.rawValue)
        s.units[near].o.flags.insert(.byScenario)
        // A far enemy tank well outside the 16-tile reaction radius ⇒ untouched.
        let far = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 2)!
        s.units[far].o.position = Tile32.unpack(50 * 64 + 50)
        s.units[far].o.hitpoints = 200

        let originEnc = s.indexEncode(s.units[origin].o.index, type: .unit)
        combat.movement.mapMakeExplosion(type: 0, position: pos, hitpoints: 30, origin: originEnc, in: &s)

        #expect(s.units[near].o.hitpoints == 170)                                  // 30 >> 0 at distance 0
        #expect(s.units[far].o.hitpoints == 200)                                   // out of range
        #expect(s.units[near].actionID == UInt8(ActionType.hunt.rawValue))         // GUARD+byScenario ⇒ HUNT
        #expect(s.units[near].targetAttack == originEnc)                           // retaliates at the firer

        // hitpoints 0 ⇒ a pure visual blast: no damage, no reaction.
        s.units[far].actionID = UInt8(ActionType.guard_.rawValue)
        combat.movement.mapMakeExplosion(type: 0, position: Tile32.unpack(50 * 64 + 50), hitpoints: 0, origin: originEnc, in: &s)
        #expect(s.units[far].o.hitpoints == 200)
    }
}
