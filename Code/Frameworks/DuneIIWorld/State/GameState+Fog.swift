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
        if let s = structureGetByPackedTile(packed) { structures[s].o.seenByHouses |= (1 << houseID) }
        // SEAM: Map_MarkTileDirty / Map_Update / structure isDirty — render dirty-marking.
        return true
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

    /// `Unit_RemoveFog` (`unit.c:1217`): lift the fog around a unit by its type's `fogUncoverRadius`. An
    /// unplaced unit (position 0:0) reveals nothing.
    mutating func unitRemoveFog(_ slot: Int) {
        let pos = units[slot].o.position
        if pos.x == 0 && pos.y == 0 { return }
        guard let ut = UnitType(rawValue: Int(units[slot].o.type)) else { return }
        tileRemoveFogInRadius(pos, radius: UInt16(UnitInfo[ut].o.fogUncoverRadius))
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
