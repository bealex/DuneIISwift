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

    /// `Map_SearchSpice` (`map.c:1117`): the nearest harvestable spice tile within `radius` of `packed`
    /// (preferring thick spice closer than 4, else any spice), skipping tiles with a structure or a
    /// unit. Returns the packed position, or `0` if none was found. Read-only.
    func searchSpice(_ packed: UInt16, radius: UInt16, in state: GameState) -> UInt16

    /// `Map_FillCircleWithSpice` (`map.c:687`): grow spice by one step on every tile within `radius` of
    /// `packed` (the circle's edge tiles are kept ~half the time via one `Random256` draw each), then once
    /// more on the centre. A no-op for `radius == 0`. Used by spice-bloom detonation + harvester death.
    func fillCircleWithSpice(_ packed: UInt16, radius: UInt16, in state: inout GameState)

    /// `Map_FindLocationTile` (`map.c:917`): a random valid spawn tile for `locationID` (0-3 = the four
    /// map edges N/E/S/W, 4 = anywhere ("Air"), 5 = within the radar viewport, 6 = an enemy base, 7 = the
    /// house's own base), retried until it lands on an unoccupied in-map tile. Draws `RandomLCG` per
    /// attempt (and `Random256` for the base cases 6/7). Returns the packed tile.
    func findLocationTile(_ locationID: UInt16, houseID: UInt8, in state: inout GameState) -> UInt16
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

        if let id = state.iconMap?.tileID(group: 9, offset: spriteOffset) {  // ICM_ICONGROUP_LANDSCAPE
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
                spriteOffset |= (1 << i)  // both spice types treat off-map as matching
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

    public func fillCircleWithSpice(_ packed: UInt16, radius: UInt16, in state: inout GameState) {
        if radius == 0 { return }
        let x = Int(Tile32.packedX(packed))
        let y = Int(Tile32.packedY(packed))
        let r = Int(radius)
        for i in -r ... r {
            for j in -r ... r {
                let curPacked = Tile32.packXY(
                    x: UInt16(truncatingIfNeeded: x + j),
                    y: UInt16(truncatingIfNeeded: y + i)
                )
                let distance = Tile32.distancePacked(packed, curPacked)
                if distance > radius { continue }
                if distance == radius && (state.random256.next() & 1) == 0 { continue }
                if landscapeType(state.map[Int(curPacked)], tileIDs: state.tileIDs) == .spice { continue }
                changeSpiceAmount(curPacked, 1, in: &state)
            }
        }
        changeSpiceAmount(packed, 1, in: &state)
    }

    public func findLocationTile(_ locationID: UInt16, houseID houseID0: UInt8, in state: inout GameState) -> UInt16 {
        let mapBase: [Int] = [ 1, -2, -2 ]
        let info = MapInfo.scales[Int(state.mapScale)]
        let mapOffset = mapBase[Int(state.mapScale)]
        var houseID = houseID0
        var ret: UInt16 = 0

        func packXYi(_ x: Int, _ y: Int) -> UInt16 {
            Tile32.packXY(x: UInt16(truncatingIfNeeded: x), y: UInt16(truncatingIfNeeded: y))
        }

        if locationID == 6 {  // an enemy's house, used as the base-search house below
            var find = PoolFind()
            while let s = state.structureFind(&find) {
                let st = state.structures[s].o.type
                if st == UInt8(StructureType.slab1x1.rawValue) || st == UInt8(StructureType.slab2x2.rawValue)
                        || st == UInt8(StructureType.wall.rawValue) {
                    continue
                }
                if state.structures[s].o.houseID == houseID { continue }
                houseID = state.structures[s].o.houseID
                break
            }
        }

        while ret == 0 {
            switch locationID {
                case 0:  // North
                    ret = packXYi(
                        Int(info.minX) + Int(state.randomLCG.range(0, info.sizeX - 2)),
                        Int(info.minY) + mapOffset
                    )
                case 1:  // East
                    ret = packXYi(
                        Int(info.minX) + Int(info.sizeX) - mapOffset,
                        Int(info.minY) + Int(state.randomLCG.range(0, info.sizeY - 2))
                    )
                case 2:  // South
                    ret = packXYi(
                        Int(info.minX) + Int(state.randomLCG.range(0, info.sizeX - 2)),
                        Int(info.minY) + Int(info.sizeY) - mapOffset
                    )
                case 3:  // West
                    ret = packXYi(
                        Int(info.minX) + mapOffset,
                        Int(info.minY) + Int(state.randomLCG.range(0, info.sizeY - 2))
                    )
                case 4:  // Air
                    ret = packXYi(
                        Int(info.minX) + Int(state.randomLCG.range(0, info.sizeX)),
                        Int(info.minY) + Int(state.randomLCG.range(0, info.sizeY))
                    )
                    if houseID == state.playerHouseID && !isValidPosition(ret, mapScale: state.mapScale) { ret = 0 }
                case 5:  // Visible (within the radar viewport)
                    ret = packXYi(
                        Int(Tile32.packedX(state.minimapPosition)) + Int(state.randomLCG.range(0, 14)),
                        Int(Tile32.packedY(state.minimapPosition)) + Int(state.randomLCG.range(0, 9))
                    )
                    if houseID == state.playerHouseID && !isValidPosition(ret, mapScale: state.mapScale) { ret = 0 }
                case 6, 7:  // Enemy base / Home base — near a structure, else a unit, else anywhere
                    var find = PoolFind(houseID: houseID)
                    if let s = state.structureFind(&find) {
                        ret =
                            Tile32.moveByRandom(
                                state.structures[s].o.position,
                                distance: 120,
                                center: true,
                                rng: &state.random256
                            ).packed
                    } else {
                        var uf = PoolFind(houseID: houseID)
                        if let u = state.unitFind(&uf) {
                            ret =
                                Tile32.moveByRandom(
                                    state.units[u].o.position,
                                    distance: 120,
                                    center: true,
                                    rng: &state.random256
                                ).packed
                        } else {
                            ret = packXYi(
                                Int(info.minX) + Int(state.randomLCG.range(0, info.sizeX)),
                                Int(info.minY) + Int(state.randomLCG.range(0, info.sizeY))
                            )
                        }
                    }
                    if houseID == state.playerHouseID && !isValidPosition(ret, mapScale: state.mapScale) { ret = 0 }
                default:
                    return 0
            }
            ret &= 0xFFF
            if ret != 0 && (state.unitGetByPackedTile(ret) != nil || state.structureGetByPackedTile(ret) != nil) {
                ret = 0
            }
        }
        return ret
    }

    public func searchSpice(_ packed: UInt16, radius: UInt16, in state: GameState) -> UInt16 {
        var radius1 = radius &+ 1  // best plain-spice distance seen
        var radius2 = radius &+ 1  // best thick-spice distance seen
        var packed1 = packed
        var packed2 = packed
        var found = false

        let info = MapInfo.scales[Int(state.mapScale)]
        // Bounds are computed signed (C promotes the uint16 subtraction to int before max/min).
        let px = Int(Tile32.packedX(packed)), py = Int(Tile32.packedY(packed))
        let xmin = max(px - Int(radius), Int(info.minX))
        let xmax = min(px + Int(radius), Int(info.minX) + Int(info.sizeX) - 1)
        let ymin = max(py - Int(radius), Int(info.minY))
        let ymax = min(py + Int(radius), Int(info.minY) + Int(info.sizeY) - 1)

        var y = ymin
        while y <= ymax {
            var x = xmin
            while x <= xmax {
                defer { x += 1 }
                let curPacked = Tile32.packXY(x: UInt16(x), y: UInt16(y))
                if !isValidPosition(curPacked, mapScale: state.mapScale) { continue }
                if state.map[Int(curPacked)].hasStructure { continue }
                if state.unitGetByPackedTile(curPacked) != nil { continue }

                let type = landscapeType(state.map[Int(curPacked)], tileIDs: state.tileIDs)
                let distance = Tile32.distancePacked(curPacked, packed)

                if type == .thickSpice && distance < 4 {
                    found = true
                    if distance <= radius2 { radius2 = distance; packed2 = curPacked }
                }
                if type == .spice {
                    found = true
                    if distance <= radius1 { radius1 = distance; packed1 = curPacked }
                }
            }
            y += 1
        }

        if !found { return 0 }
        return (radius2 <= radius) ? packed2 : packed1
    }

    /// `g_table_mapDiff[4]` (`table/tilediff.c`): packed-offset deltas for the four orthogonal
    /// neighbours (up, right, down, left).
    static let mapDiff: [Int16] = [ -64, 1, 64, -1 ]

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
