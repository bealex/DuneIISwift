import DuneIIContracts
import Testing

@testable import DuneIIWorld

/// Fog-of-war primitives (`Map_UnveilTile` / `Tile_RemoveFogInRadius` / `Unit_RemoveFog`): the player's
/// tile visibility + the `seenByHouses` reveal it drives, plus the continuous radius-1 reveal that
/// `unitUpdateMap(1)` performs every time a player unit steps onto a new tile (`Unit_UpdateMap`).
@Suite("Fog of war")
struct FogTests {
    private func world() -> GameState {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        return s
    }

    @Test("Map_UnveilTile lifts the player's fog only, and reveals an enemy standing there")
    func unveil() {
        var s = world()
        // An enemy unit on tile 1040, registered on the map so Unit_Get_ByPackedTile finds it.
        let enemy = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 2)!
        s.units[enemy].o.flags.insert([ .used, .allocated ])
        s.units[enemy].o.position = Tile32.unpack(1040)
        s.map[1040].hasUnit = true
        s.map[1040].index = UInt8(enemy + 1)

        #expect(!s.map[1040].isUnveiled)
        #expect(s.mapUnveilTile(1040, houseID: 1) == false)  // non-player ⇒ no-op
        #expect(!s.map[1040].isUnveiled)

        #expect(s.mapUnveilTile(1040, houseID: 0) == true)  // player ⇒ unveils
        #expect(s.map[1040].isUnveiled)
        #expect(s.units[enemy].o.seenByHouses & (1 << 0) != 0)  // enemy now seen by the player
        #expect(s.mapUnveilTile(1040, houseID: 0) == false)  // already clear ⇒ no-op
    }

    @Test("Tile_RemoveFogInRadius unveils the disc within the radius")
    func radius() {
        var s = world()
        let centre = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.tileRemoveFogInRadius(centre, radius: 1)

        // Centre + its 4 orthogonal neighbours are within rounded distance 1; diagonals are distance 2.
        #expect(s.map[Int(Tile32.packXY(x: 10, y: 10))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 11, y: 10))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 9, y: 10))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 10, y: 11))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 10, y: 9))].isUnveiled)
        #expect(!s.map[Int(Tile32.packXY(x: 11, y: 11))].isUnveiled)  // diagonal ⇒ out of radius 1
        #expect(!s.map[Int(Tile32.packXY(x: 12, y: 10))].isUnveiled)  // 2 away
    }

    @Test("unitUpdateMap(1) continuously reveals radius-1 for a player unit, not for an enemy or a sandworm")
    func updateMapContinuousReveal() {
        // A player-house (0) tank: stamping its tile via unitUpdateMap(1) lifts fog radius-1 around it.
        var s = world()
        let mine = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        s.units[mine].o.flags.insert([ .used, .allocated ])
        s.units[mine].o.position = Tile32.unpack(Tile32.packXY(x: 30, y: 30))
        s.unitUpdateMap(1, mine)
        #expect(s.map[Int(Tile32.packXY(x: 30, y: 30))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 31, y: 30))].isUnveiled)  // radius-1 orthogonal neighbour
        #expect(!s.map[Int(Tile32.packXY(x: 32, y: 30))].isUnveiled)  // beyond radius 1

        // An enemy (house 2 ≠ player) tank reveals nothing (fog is player-only).
        let enemy = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 2)!
        s.units[enemy].o.flags.insert([ .used, .allocated ])
        s.units[enemy].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.unitUpdateMap(1, enemy)
        #expect(!s.map[Int(Tile32.packXY(x: 10, y: 10))].isUnveiled)

        // A player-house sandworm is excluded (it shouldn't betray its position by lifting fog).
        let worm = s.unitAllocate(index: 0, type: UInt8(UnitType.sandworm.rawValue), houseID: 0)!
        s.units[worm].o.flags.insert([ .used, .allocated ])
        s.units[worm].o.position = Tile32.unpack(Tile32.packXY(x: 50, y: 50))
        s.unitUpdateMap(1, worm)
        #expect(!s.map[Int(Tile32.packXY(x: 50, y: 50))].isUnveiled)
    }

    @Test("Unit_RemoveFog reveals around a placed unit, but an unplaced unit reveals nothing")
    func unitFog() {
        var s = world()
        let u = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        s.units[u].o.flags.insert([ .used, .allocated ])

        // Position 0:0 ⇒ treated as unplaced ⇒ no reveal.
        s.units[u].o.position = Tile32(x: 0, y: 0)
        s.unitRemoveFog(u)
        #expect(!s.map[0].isUnveiled)

        // Placed ⇒ reveals at least its own tile (tank fogUncoverRadius > 0).
        s.units[u].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        s.unitRemoveFog(u)
        #expect(s.map[Int(Tile32.packXY(x: 20, y: 20))].isUnveiled)
    }
}

/// The debug `aiFogOfWar` test mode (`Architecture/AIFogOfWar.md`): with the flag off the player's objects
/// reveal to all houses (stock 1.07); with it on, an AI house only sees the player's base after the player
/// makes contact with one of its objects.
@Suite("AI fog of war (debug)")
struct AIFogTests {
    private func world() -> GameState {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        return s
    }

    /// Place an on-map unit of `house` at `packed`, registered so `unitGetByPackedTile` finds it.
    private func place(_ s: inout GameState, type: UnitType, house: UInt8, at packed: UInt16) -> Int {
        let u = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: house)!
        s.units[u].o.flags.insert([ .used, .allocated ])
        s.units[u].o.position = Tile32.unpack(packed)
        s.map[Int(packed)].hasUnit = true
        s.map[Int(packed)].index = UInt8(u + 1)
        return u
    }

    @Test("the visibility mask is 0xFF with the flag off, player+found with it on")
    func mask() {
        var s = world()
        #expect(s.playerObjectVisibilityMask() == 0xFF)  // stock: seen by all
        s.aiFogOfWar = true
        #expect(s.playerObjectVisibilityMask() == UInt8(1 << 0))  // only the player (house 0)
        s.housesFoundPlayer = UInt8(1 << 2)  // house 2 has found the player
        #expect(s.playerObjectVisibilityMask() == UInt8(1 << 0 | 1 << 2))
    }

    @Test("flag off (stock): a player unit is seen by all houses on sight")
    func stockUnitRevealsToAll() {
        var s = world()
        let mine = place(&s, type: .tank, house: 0, at: Tile32.packXY(x: 30, y: 30))
        s.unitHouseUnitCountAdd(mine, houseID: s.playerHouseID)
        #expect(s.units[mine].o.seenByHouses == 0xFF)
    }

    @Test("flag on: a player unit stays hidden from the AI until contact")
    func playerUnitHiddenUntilContact() {
        var s = world()
        s.aiFogOfWar = true
        let mine = place(&s, type: .tank, house: 0, at: Tile32.packXY(x: 30, y: 30))
        s.unitHouseUnitCountAdd(mine, houseID: s.playerHouseID)
        #expect(s.units[mine].o.seenByHouses == UInt8(1 << 0))  // only the player sees it
        #expect(s.units[mine].o.seenByHouses & (1 << 2) == 0)  // the AI (house 2) does not
    }

    @Test("flag on: the player sighting an enemy unit reveals the whole player base to that house")
    func contactRevealsBase() {
        var s = world()
        s.aiFogOfWar = true
        // The player's existing army/base — hidden from the AI so far.
        let mine = place(&s, type: .tank, house: 0, at: Tile32.packXY(x: 30, y: 30))
        s.unitHouseUnitCountAdd(mine, houseID: s.playerHouseID)
        #expect(s.units[mine].o.seenByHouses & (1 << 2) == 0)
        #expect(s.housesFoundPlayer == 0)

        // An enemy (house 2) tank the player now sights via Map_UnveilTile ⇒ contact.
        _ = place(&s, type: .tank, house: 2, at: Tile32.packXY(x: 10, y: 10))
        let unveiled = s.mapUnveilTile(Tile32.packXY(x: 10, y: 10), houseID: 0)
        #expect(unveiled)

        // House 2 has now found the player: it is recorded, and the pre-existing player tank is back-filled.
        #expect(s.housesFoundPlayer & (1 << 2) != 0)
        #expect(s.units[mine].o.seenByHouses & (1 << 2) != 0)
        // A player unit created *after* contact also carries house 2 via the mask.
        let later = place(&s, type: .tank, house: 0, at: Tile32.packXY(x: 31, y: 30))
        s.unitHouseUnitCountAdd(later, houseID: s.playerHouseID)
        #expect(s.units[later].o.seenByHouses & (1 << 2) != 0)
    }

    @Test("the load flow (unitUpdateMap for every unit) does NOT reveal the base to a far enemy in fog")
    func loadDoesNotRevealFarEnemy() {
        var s = world()
        s.aiFogOfWar = true
        // The player's base unit, placed like the loader does.
        let mine = place(&s, type: .tank, house: 0, at: Tile32.packXY(x: 30, y: 30))
        s.unitUpdateMap(1, mine)
        // An enemy (house 2) unit far away on a *fogged* tile — the loader runs unitUpdateMap for every unit,
        // enemies included; its tile isn't unveiled, so this is not player contact.
        let enemy = place(&s, type: .tank, house: 2, at: Tile32.packXY(x: 5, y: 5))
        s.unitUpdateMap(1, enemy)
        #expect(s.housesFoundPlayer == 0)  // no contact ⇒ the base stays hidden
        #expect(s.units[mine].o.seenByHouses & (1 << 2) == 0)  // the AI still can't see the player unit
    }

    @Test("reapplyPlayerVisibility re-hides a base that was placed while the flag was off (the toggle-after-load fix)")
    func reapplyHidesExistingBase() {
        var s = world()
        // Placed while the flag was OFF ⇒ seen by all houses (incl. the AI), as in stock.
        let mine = place(&s, type: .tank, house: 0, at: Tile32.packXY(x: 30, y: 30))
        s.unitHouseUnitCountAdd(mine, houseID: 0)
        let base = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[base].o.flags.insert([ .used, .allocated ]); s.structures[base].o.houseID = 0
        s.structures[base].o.seenByHouses = 0xFF
        #expect(s.units[mine].o.seenByHouses == 0xFF)

        // Turn the flag on mid-game + reapply ⇒ the AI (house 2) can no longer see the base.
        s.aiFogOfWar = true
        s.reapplyPlayerVisibility()
        #expect(s.housesFoundPlayer == 0)
        #expect(s.units[mine].o.seenByHouses == UInt8(1 << 0))  // only the player
        #expect(s.structures[base].o.seenByHouses == UInt8(1 << 0))
    }
}
