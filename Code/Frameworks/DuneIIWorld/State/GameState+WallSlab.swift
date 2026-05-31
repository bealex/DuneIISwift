import DuneIIContracts

/// Placement of the two "structures" that are really just map tiles — concrete **slabs** and **walls**.
/// Unlike a building, a slab/wall is stamped straight into the map's ground tiles and then has **no
/// structure object** (`Structure_Place` `Structure_Free`s it, `structure.c:442`). They are not in the
/// structure find array, so `GameLoop_Structure` never runs a script for them — which is why, before
/// this, scenario-loaded slabs/walls were allocated but never drawn: nothing ever stamped their tiles.
public extension GameState {
    /// `Structure_Place` (slab case): paint each footprint tile with the built-concrete tile.
    mutating func placeSlab(_ type: StructureType, houseID: UInt8, at packed: UInt16) {
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        for i in 0 ..< Int(layout.tileCount) {
            let pos = Int(packed) + Int(layout.tiles[i])
            guard pos >= 0, pos < map.count else { continue }
            map[pos].groundTileID = tileIDs.builtSlab
            map[pos].houseID = houseID
            // SEAM: Tile_RemoveFogInRadius (player fog) + the unveiled-overlay clear (render-only).
        }
        mapDirty = true
    }

    /// `Structure_Place` (wall case): paint the base wall tile, then connect it to its neighbours.
    mutating func placeWall(houseID: UInt8, at packed: UInt16) {
        let pos = Int(packed)
        guard pos >= 0, pos < map.count else { return }
        map[pos].groundTileID = tileIDs.wall &+ 1
        map[pos].houseID = houseID
        structureConnectWall(packed, recurse: true)
        mapDirty = true
    }

    /// `Structure_ConnectWall` (`structure.c:1136`): pick the wall's ground tile from which of its four
    /// cardinal neighbours are walls (a 256-entry lookup), and — when `recurse` — re-connect those wall
    /// neighbours so the join stays consistent as a wall network is built up one tile at a time.
    @discardableResult
    mutating func structureConnectWall(_ packed: UInt16, recurse: Bool) -> Bool {
        let pos = Int(packed)
        guard pos >= 0, pos < map.count else { return false }
        let isDestroyed = wallTileIsDestroyed(pos)

        var bits = 0
        for i in 0 ..< 4 {
            let cur = pos + GameState.wallMapDiff[i]
            guard cur >= 0, cur < map.count else { continue }
            if recurse && wallTileIsWall(cur) { structureConnectWall(UInt16(cur), recurse: false) }
            if isDestroyed { continue }
            if wallTileIsDestroyed(cur) { bits |= (1 << (i + 4)); bits |= (1 << i) }
            else if wallTileIsWall(cur) { bits |= (1 << i) }
        }
        if isDestroyed { return false }

        let tileID = tileIDs.wall &+ UInt16(GameState.wallConnectTable[bits]) &+ 1
        if map[pos].groundTileID == tileID { return false }
        map[pos].groundTileID = tileID
        mapDirty = true
        return true
    }

    /// `Map_GetLandscapeType == LST_WALL` (`map.c`): a ground tile inside the WALLS sprite band.
    private func wallTileIsWall(_ pos: Int) -> Bool {
        let g = map[pos].groundTileID
        return g > tileIDs.wall && g < tileIDs.wall &+ 75
    }
    /// `LST_DESTROYED_WALL`: a rubble overlay left where a wall was destroyed.
    private func wallTileIsDestroyed(_ pos: Int) -> Bool {
        UInt16(map[pos].overlayTileID) == tileIDs.wall
    }
}

private extension GameState {
    /// `g_table_mapDiff` (`table/tilediff.c`): the four cardinal neighbours in packed order N, E, S, W.
    static let wallMapDiff: [Int] = [-64, 1, 64, -1]

    /// `Structure_ConnectWall`'s `wall[256]` table: neighbour-bitmask → WALLS sprite offset.
    static let wallConnectTable: [UInt8] = [
         0,  3,  1,  2,  3,  3,  4,  5,  1,  6,  1,  7,  8,  9, 10, 11,
         1, 12,  1, 19,  1, 16,  1, 31,  1, 28,  1, 52,  1, 45,  1, 59,
         3,  3, 13, 20,  3,  3, 22, 32,  3,  3, 13, 53,  3,  3, 38, 60,
         5,  6,  7, 21,  5,  6,  7, 33,  5,  6,  7, 54,  5,  6,  7, 61,
         9,  9,  9,  9, 17, 17, 23, 34,  9,  9,  9,  9, 25, 46, 39, 62,
        11, 12, 11, 12, 13, 18, 13, 35, 11, 12, 11, 12, 13, 47, 13, 63,
        15, 15, 16, 16, 17, 17, 24, 36, 15, 15, 16, 16, 17, 17, 40, 64,
        19, 20, 21, 22, 23, 24, 25, 37, 19, 20, 21, 22, 23, 24, 25, 65,
        27, 27, 27, 27, 27, 27, 27, 27, 14, 29, 14, 55, 26, 48, 41, 66,
        29, 30, 29, 30, 29, 30, 29, 30, 31, 30, 31, 56, 31, 49, 31, 67,
        33, 33, 34, 34, 33, 33, 34, 34, 35, 35, 15, 57, 35, 35, 42, 68,
        37, 38, 39, 40, 37, 38, 39, 40, 41, 42, 43, 58, 41, 42, 43, 69,
        45, 45, 45, 45, 46, 46, 46, 46, 47, 47, 47, 47, 27, 50, 43, 70,
        49, 50, 49, 50, 51, 52, 51, 52, 53, 54, 53, 54, 55, 51, 55, 71,
        57, 57, 58, 58, 59, 59, 60, 60, 61, 61, 62, 62, 63, 63, 44, 72,
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 73,
    ]
}
