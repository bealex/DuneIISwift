import DuneIIContracts

/// Fog of war — the player's tile visibility (`Tile.isUnveiled`) and the per-object `seenByHouses`
/// reveal it drives. Faithful ports of `Map_UnveilTile` (`map.c:1129`), `Tile_RemoveFogInRadius`
/// (`map.c:1196`), and `Unit_RemoveFog` (`unit.c:1217`). Fog is **player-only** in Dune II (only the
/// local player has fog; AI houses see via objects' `seenByHouses`), so `Map_UnveilTile` is a no-op for
/// non-player houses. The render-only effects (`Map_MarkTileDirty`/`Map_Update`, the partial-fog overlay
/// sprite, a structure's `isDirty`) are seams; the deterministic sim state — the `isUnveiled` bit and the
/// occupant `seenByHouses` reveal — is ported here.
public extension GameState {
    /// `Map_UnveilTile` (`map.c:1129`): lift the fog on `packed` for the player, revealing any unit /
    /// structure standing on it (their `seenByHouses` gains the player). No-op for non-player houses, an
    /// off-map tile, or an already-clear tile. Returns true if it unveiled the tile.
    @discardableResult
    mutating func mapUnveilTile(_ packed: UInt16, houseID: UInt8) -> Bool {
        if houseID != playerHouseID { return false }
        if Tile32.isOutOfMap(packed) { return false }

        // Already unveiled ⇒ nothing to do. (OpenDUNE re-unveils a tile still showing the partial-fog
        // overlay sprite via `Tile_IsUnveiled(overlayTileID)`; we don't model that overlay headlessly —
        // `overlayTileID` stays 0 = fully clear — so a set `isUnveiled` is final here.)
        if map[Int(packed)].isUnveiled { return false }
        map[Int(packed)].isUnveiled = true
        map[Int(packed)].overlayTileID = 0

        if let u = unitGetByPackedTile(packed) { unitHouseUnitCountAdd(u, houseID: houseID) }
        if let s = structureGetByPackedTile(packed) {
            structures[s].o.seenByHouses |= (1 << houseID)
            // Debug `aiFogOfWar`: the player sighting an enemy structure is contact — reveal the base to it.
            let sHouse = structures[s].o.houseID
            if !House.areAllied(houseID, sHouse, playerHouseID: playerHouseID) { aiFogReveal(toEnemyHouse: sHouse) }
        }
        // SEAM: Map_MarkTileDirty / Map_Update / structure isDirty — render dirty-marking.
        return true
    }

    /// **Debug `aiFogOfWar` (default off, no-op).** The `seenByHouses` bits a freshly placed/created
    /// **player-owned** object should carry. Stock Dune II reveals every player object to all houses
    /// (`0xFF`); with `aiFogOfWar` on, a new object is seen only by the player plus any AI house that has
    /// already found the player (`housesFoundPlayer`).
    func playerObjectVisibilityMask() -> UInt8 {
        aiFogOfWar ? (UInt8(1 << playerHouseID) | housesFoundPlayer) : 0xFF
    }

    /// **Debug `aiFogOfWar` (default off, no-op).** The player has made contact with enemy house `h`
    /// (sighted one of its objects). Reveal the whole player base/army to that house — it now commits, as
    /// if it had scouted the player out. Idempotent (a no-op once `h` has already found the player).
    mutating func aiFogReveal(toEnemyHouse h: UInt8) {
        guard aiFogOfWar else { return }
        let bit = UInt8(1 << h)
        if housesFoundPlayer & bit != 0 { return }
        housesFoundPlayer |= bit
        for i in units.indices where units[i].o.flags.contains(.used) && units[i].o.houseID == playerHouseID {
            units[i].o.seenByHouses |= bit
        }
        for i in structures.indices
        where structures[i].o.flags.contains(.used) && structures[i].o.houseID == playerHouseID {
            structures[i].o.seenByHouses |= bit
        }
    }

    /// Re-apply the **current** `aiFogOfWar` setting to every existing player-owned object — used when the
    /// duneii toggle flips **mid-game / after a scenario is already loaded** (the live objects were placed
    /// under the old setting). Turning the flag **on** re-hides the player base from the AI (resets each
    /// player object to the player bit + clears `housesFoundPlayer`, so the AI must re-discover via contact);
    /// turning it **off** restores the stock all-houses visibility (`0xFF`).
    mutating func reapplyPlayerVisibility() {
        housesFoundPlayer = 0
        let v = playerObjectVisibilityMask()  // 0xFF off, (1<<playerHouseID) on (housesFoundPlayer now 0)
        for i in units.indices where units[i].o.flags.contains(.used) && units[i].o.houseID == playerHouseID {
            units[i].o.seenByHouses = v
        }
        for i in structures.indices
        where structures[i].o.flags.contains(.used) && structures[i].o.houseID == playerHouseID {
            structures[i].o.seenByHouses = v
        }
    }

    /// `Tile_RemoveFogInRadius` (`map.c:1196`): unveil (for the player) every in-bounds tile whose centre
    /// is within `radius` (rounded-up tile distance) of `tile`.
    mutating func tileRemoveFogInRadius(_ tile: Tile32, radius: UInt16) {
        let packed = tile.packed
        if Tile32.isOutOfMap(packed) { return }

        let x = Int(Tile32.packedX(packed))
        let y = Int(Tile32.packedY(packed))
        // OpenDUNE `Tile_MakeXY`s both the centre and each candidate from their tile coords, so both carry
        // the same sub-tile offset — use the centred `unpack` for both so the distance is symmetric.
        let centre = Tile32.unpack(packed)
        let r = Int(radius)

        for j in -r ... r {
            for i in -r ... r {
                if x + i < 0 || x + i >= 64 { continue }
                if y + j < 0 || y + j >= 64 { continue }
                let curPacked = Tile32.packXY(x: UInt16(x + i), y: UInt16(y + j))
                let t = Tile32.unpack(curPacked)
                if Tile32.distanceRoundedUp(from: centre, to: t) <= radius {
                    mapUnveilTile(curPacked, houseID: playerHouseID)
                }
            }
        }
    }

    /// `Unit_RemoveFog` (`unit.c:1217`): lift the **player's** fog around a unit by its type's
    /// `fogUncoverRadius`. Skips an off-map / unplaced unit (position `0xFFFF` or `0:0`), a radius of 0, and —
    /// crucially — **a unit not allied to the player**: only the player's own/allied units reveal the player's
    /// fog. Without that check every enemy unit would unveil the player's fog around itself (the player would
    /// "see" all enemies + make contact at once — the `aiFogOfWar` + render-fog bug this fixes).
    mutating func unitRemoveFog(_ slot: Int) {
        let u = units[slot]
        if u.o.flags.contains(.isNotOnMap) { return }
        let pos = u.o.position
        if (pos.x == 0xFFFF && pos.y == 0xFFFF) || (pos.x == 0 && pos.y == 0) { return }
        if !House.areAllied(unitHouseID(u), playerHouseID, playerHouseID: playerHouseID) { return }
        guard let ut = UnitType(rawValue: Int(u.o.type)) else { return }
        let radius = UInt16(UnitInfo[ut].o.fogUncoverRadius)
        if radius == 0 { return }
        tileRemoveFogInRadius(pos, radius: radius)
    }

    /// `Structure_RemoveFog` (`structure.c:954`): lift the fog around a player-owned structure by its
    /// type's `fogUncoverRadius`. AI houses reveal nothing. We pin the non-enhanced (1.07) path: the fog
    /// disc is centred on the structure's origin tile, not its visual centre.
    mutating func structureRemoveFog(_ slot: Int) {
        guard structures[slot].o.houseID == playerHouseID else { return }
        guard let st = StructureType(rawValue: Int(structures[slot].o.type)) else { return }
        tileRemoveFogInRadius(structures[slot].o.position, radius: UInt16(StructureInfo[st].o.fogUncoverRadius))
    }
}
