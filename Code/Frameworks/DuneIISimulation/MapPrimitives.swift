import DuneIIContracts
import DuneIIFormats
import DuneIIWorld

/// The replaceable seam for the native map primitives ported from OpenDUNE `src/map.c`. Injected into
/// `Simulation` so the implementation can be swapped (see `UnitPrimitives`).
public protocol MapPrimitives: Sendable {
    /// `Map_IsValidPosition` (`map.c`): is `position` (a packed tile) inside the playable bounds for
    /// `mapScale`? (Out-of-map bits, then the per-scale `MapInfo` rectangle.)
    func isValidPosition(_ position: UInt16, mapScale: UInt8) -> Bool

    /// `Map_GetLandscapeType` (`map.c`): classify a tile from its ground/overlay ids + the runtime
    /// tile-id bases. The structure case is just the tile's `hasStructure` flag.
    func landscapeType(_ tile: MapTile, tileIDs: TileIDs) -> LandscapeType

    /// `Tile_IsUnveiled` (`sprites.c:477`): is `tileID` outside the 16-frame fog-of-war veil run that
    /// ends at `veiledTileID`? (Anything above the run, or below its start, is unveiled terrain.)
    func tileIsUnveiled(_ tileID: UInt16, veiledTileID: UInt16) -> Bool

    /// `Map_IsPositionUnveiled` (`map.c:341`): is the tile both flagged `isUnveiled` and showing a
    /// non-veil overlay? (OpenDUNE's `g_debugScenario` short-circuit is a dev mode we don't model.)
    func isPositionUnveiled(_ tile: MapTile, tileIDs: TileIDs) -> Bool

    /// `Map_ChangeSpiceAmount` (`map.c:771`): grow (`dir > 0`) or deplete (`dir < 0`) spice on `packed`
    /// by one step, retiling it (sand↔spice↔thick-spice) and fixing the spice-edge sprites on the tile
    /// and its four neighbours. No-op when the transition isn't legal for the tile's landscape type.
    /// Mutates `state.map`/`state.mapBaseTileID`; the render dirty-marking (`Map_Update`) is a seam we
    /// skip here.
    func changeSpiceAmount(_ packed: UInt16, _ dir: Int16, in state: inout GameState)
}

public struct DefaultMapPrimitives: MapPrimitives {
    public init() {}

    public func isValidPosition(_ position: UInt16, mapScale: UInt8) -> Bool {
        if position & 0xC000 != 0 { return false }
        let x = UInt16(Tile32.packedX(position))
        let y = UInt16(Tile32.packedY(position))
        let info = MapInfo.scales[Int(mapScale)]
        return info.minX <= x && x < info.minX + info.sizeX
            && info.minY <= y && y < info.minY + info.sizeY
    }

    public func landscapeType(_ tile: MapTile, tileIDs: TileIDs) -> LandscapeType {
        let ground = tile.groundTileID
        if ground == tileIDs.builtSlab { return .concreteSlab }
        if ground == tileIDs.bloom || ground == tileIDs.bloom + 1 { return .bloomField }
        if ground > tileIDs.wall && ground < tileIDs.wall + 75 { return .wall }
        if UInt16(tile.overlayTileID) == tileIDs.wall { return .destroyedWall }
        if tile.hasStructure { return .structure }
        let offset = Int(ground) - Int(tileIDs.landscape)
        if offset < 0 || offset > 80 { return .entirelyRock }
        return LandscapeType(rawValue: Int(DefaultMapPrimitives.landscapeSpriteMap[offset])) ?? .entirelyRock
    }

    public func tileIsUnveiled(_ tileID: UInt16, veiledTileID: UInt16) -> Bool {
        if tileID > veiledTileID { return true }
        if tileID < veiledTileID &- 15 { return true }
        return false
    }

    public func isPositionUnveiled(_ tile: MapTile, tileIDs: TileIDs) -> Bool {
        if !tile.isUnveiled { return false }
        if !tileIsUnveiled(UInt16(tile.overlayTileID), veiledTileID: tileIDs.veiled) { return false }
        return true
    }

    public func changeSpiceAmount(_ packed: UInt16, _ dir: Int16, in state: inout GameState) {
        if dir == 0 { return }

        var type = landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)

        if type == .thickSpice && dir > 0 { return }
        if type != .spice && type != .thickSpice && dir < 0 { return }
        if type != .normalSand && type != .entirelyDune && type != .spice && dir > 0 { return }

        if dir > 0 {
            type = (type == .spice) ? .thickSpice : .spice
        } else {
            type = (type == .thickSpice) ? .spice : .normalSand
        }

        var spriteOffset = 0
        if type == .spice { spriteOffset = 49 }
        if type == .thickSpice { spriteOffset = 65 }

        if let id = state.iconMap?.tileID(group: 9, offset: spriteOffset) {   // ICM_ICONGROUP_LANDSCAPE
            let spriteID = UInt16(id & 0x1FF)
            state.mapBaseTileID[Int(packed)] = 0x8000 | spriteID
            state.map[Int(packed)].groundTileID = spriteID
        }

        fixupSpiceEdges(packed, in: &state)
        fixupSpiceEdges(packed &+ 1, in: &state)
        fixupSpiceEdges(packed &- 1, in: &state)
        fixupSpiceEdges(packed &- 64, in: &state)
        fixupSpiceEdges(packed &+ 64, in: &state)
    }

    /// `Map_FixupSpiceEdges` (`map.c:725`): pick the correct spice-edge sprite for `packed` from which
    /// of its four neighbours also carry (thick) spice. No-op for non-spice tiles.
    private func fixupSpiceEdges(_ packed: UInt16, in state: inout GameState) {
        let packed = packed & 0xFFF
        let type = landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
        guard type == .spice || type == .thickSpice else { return }

        var spriteOffset = 0
        for i in 0 ..< 4 {
            let curPacked = Int(packed) + Int(DefaultMapPrimitives.mapDiff[i])
            if Tile32.isOutOfMap(UInt16(truncatingIfNeeded: curPacked)) {
                spriteOffset |= (1 << i)   // both spice types treat off-map as matching
                continue
            }
            let curType = landscapeType(state.map[curPacked], tileIDs: state.tileIDs)
            if type == .spice {
                if curType == .spice || curType == .thickSpice { spriteOffset |= (1 << i) }
                continue
            }
            if curType == .thickSpice { spriteOffset |= (1 << i) }
        }

        spriteOffset += (type == .spice) ? 49 : 65
        if let id = state.iconMap?.tileID(group: 9, offset: spriteOffset) {
            let spriteID = UInt16(id & 0x1FF)
            state.mapBaseTileID[Int(packed)] = 0x8000 | spriteID
            state.map[Int(packed)].groundTileID = spriteID
        }
    }

    /// `g_table_mapDiff[4]` (`table/tilediff.c`): packed-offset deltas for the four orthogonal
    /// neighbours (up, right, down, left).
    static let mapDiff: [Int16] = [-64, 1, 64, -1]

    /// `_landscapeSpriteMap[81]` (`map.c:523`): landscape sprite offset (0…80, from `g_landscapeTileID`)
    /// → `LandscapeType` raw value.
    static let landscapeSpriteMap: [UInt8] = [
        0, 1, 1, 1, 5, 1, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 4, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 2, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 6, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 9, 9, 9, 9, 9,
        9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9,
    ]
}
