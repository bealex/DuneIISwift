import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Coverage for the spoken/positional feedback the sim raises into `pendingFeedback` (the
/// `Sound_Output_Feedback` announcements) and `soundEvents` (the `Voice_PlayAtTile` cues). These are
/// presentation seams — not dumped + RNG-free, so golden-neutral — verified here at the primitive level.
@Suite("Feedback announcements")
struct FeedbackAnnouncementTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base(player: UInt8 = 0) -> GameState {
        var s = GameState(random256Seed: 0x1234)
        s.playerHouseID = player
        _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100; s.houses[2].unitCountMax = 100
        return s
    }

    private func addStructure(_ s: inout GameState, _ type: StructureType, house: UInt8, hp: UInt16) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = hp
        s.structures[slot].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        return slot
    }

    // MARK: Structure destroyed (21-24) + CRUMBLE (44)

    @Test("destroying a player structure announces its house + a CRUMBLE cue; an enemy's says 'enemy'")
    func structureDestroyed() {
        var s = base(player: 0)  // player = Harkonnen → feedback 22
        let mine = addStructure(&s, .windtrap, house: 0, hp: 10)
        _ = s.structureDamage(mine, damage: 50, range: 0)
        #expect(s.pendingFeedback.contains(22))  // "<Harkonnen> structure destroyed"
        #expect(s.soundEvents.contains { $0.sound == SoundID(44) })  // Voice_PlayAtTile(44) → CRUMBLE

        var s2 = base(player: 0)
        let enemy = addStructure(&s2, .windtrap, house: 2, hp: 10)
        _ = s2.structureDamage(enemy, damage: 50, range: 0)
        #expect(s2.pendingFeedback.contains(21))  // "enemy structure destroyed"
    }

    // MARK: Radar on/off (28/29)

    @Test("radar activates when the player gains an outpost + power, deactivates when power fails")
    func radarState() {
        var s = base(player: 0)
        s.houses[0].structuresBuilt = UInt32(1) << UInt32(StructureType.outpost.rawValue)
        s.houses[0].powerProduction = 100; s.houses[0].powerUsage = 50
        s.houseUpdateRadarState(0)
        #expect(s.houses[0].flags.contains(.radarActivated))
        #expect(s.pendingFeedback.contains(28))  // "radar activated"

        s.pendingFeedback.removeAll()
        s.houses[0].powerProduction = 10  // now under-powered
        s.houseUpdateRadarState(0)
        #expect(!s.houses[0].flags.contains(.radarActivated))
        #expect(s.pendingFeedback.contains(29))  // "radar deactivated"

        // Idempotent: no further announcement when nothing changed.
        s.pendingFeedback.removeAll(); s.houseUpdateRadarState(0)
        #expect(s.pendingFeedback.isEmpty)
    }

    // MARK: Threat warnings (Unit_HouseUnitCount_Add) — sandworm (37) / saboteur (12) / approaching (1)

    private func addUnit(_ s: inout GameState, _ type: UnitType, house: UInt8) -> Int {
        let slot = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(Tile32.packXY(x: 30, y: 30))
        return slot
    }

    @Test("the player sighting a sandworm / saboteur / advancing enemy raises the right warning")
    func threatWarnings() {
        var s = base(player: 0)
        let worm = addUnit(&s, .sandworm, house: 2)
        s.unitHouseUnitCountAdd(worm, houseID: 0)
        #expect(s.pendingFeedback.contains(37))  // "sandworms roam Dune"

        var s2 = base(player: 0)
        let sabo = addUnit(&s2, .saboteur, house: 2)
        s2.unitHouseUnitCountAdd(sabo, houseID: 0)
        #expect(s2.pendingFeedback.contains(12))  // "saboteur approaching"

        // An advancing enemy with no player construction yard → the non-directional warning (1).
        var s3 = base(player: 0)
        let tank = addUnit(&s3, .tank, house: 2)
        s3.unitHouseUnitCountAdd(tank, houseID: 0)
        #expect(s3.pendingFeedback.contains(1))  // "enemy unit approaching"

        // The timer suppresses a second warning until it ticks down.
        var s4 = base(player: 0)
        s4.houses[0].timerUnitAttack = 8
        let tank2 = addUnit(&s4, .tank, house: 2)
        s4.unitHouseUnitCountAdd(tank2, houseID: 0)
        #expect(!s4.pendingFeedback.contains(1))
    }

    // MARK: Spice bloom (36) + palace house-missile (39)

    @Test("a player-detonated spice bloom announces 'bloom located'")
    func spiceBloom() {
        var s = base(player: 0)
        s.tileIDs = TileIDs()
        let movement = UnitMovement(scriptInfo: info)
        movement.mapBloomExplodeSpice(packed: Tile32.packXY(x: 20, y: 20), houseID: 0, in: &s)
        #expect(s.pendingFeedback.contains(36))

        // An enemy-detonated bloom is silent to the player.
        var s2 = base(player: 0); s2.tileIDs = TileIDs()
        movement.mapBloomExplodeSpice(packed: Tile32.packXY(x: 20, y: 20), houseID: 2, in: &s2)
        #expect(!s2.pendingFeedback.contains(36))
    }

    @Test("an AI palace's house-missile launch warns the player (39); the human launch does not")
    func palaceMissileWarning() {
        var s = base(player: 1)  // player = Atreides; the AI Harkonnen palace fires a missile
        s.houses[0].flags.insert(.isAIActive)
        let palace = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.palace.rawValue))!
        s.structures[palace].o.houseID = 0
        s.structures[palace].o.hitpoints = StructureInfo[.palace].o.hitpoints
        s.structures[palace].o.position = Tile32.unpack(Tile32.packXY(x: 32, y: 32))
        var sim = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sim.structureActivateSpecial(palace)
        #expect(sim.state.pendingFeedback.contains(39))  // "warning, missile approaching"
    }
}
