import DuneIIContracts
import DuneIIWorld

/// Builds the `sim → render` snapshot from the current `GameState`. A pure read of state (no mutation),
/// callable any time after a `tick()` — the renderer pulls one `FrameInfo` per drawn frame, decoupled
/// from the sim cadence. Unit sprite layers reuse `UnitSprites` (the `viewport.c` port). See
/// `Documentation/Architecture/FrameInfo.md`.
public extension Simulation {
    func makeFrameInfo() -> FrameInfo {
        let width = 64, height = 64    // `g_map` is a fixed 64×64 grid

        var tiles = [FrameInfo.Tile]()
        tiles.reserveCapacity(state.map.count)
        // Partial fog edges: for a revealed tile bordering the unknown, pick the fog-edge sprite for its
        // 4-neighbour veil bitmask (computed from the binary `isUnveiled` grid — the sim models fog as
        // binary, the renderer derives the soft edge). The renderer draws it only when `showFog` is on.
        let fogEdges = state.tileIDs.fogEdges
        for i in 0 ..< state.map.count {
            let tile = state.map[i]
            var fogEdge = 0
            if tile.isUnveiled, !fogEdges.isEmpty {
                let mask = Self.fogEdgeMask(packed: i, width: width, height: height) { state.map[$0].isUnveiled }
                if mask != 0 { fogEdge = Int(fogEdges[mask]) }
            }
            tiles.append(FrameInfo.Tile(groundSpriteIndex: Int(tile.groundTileID),
                                        overlaySpriteIndex: Int(tile.overlayTileID),
                                        houseID: tile.houseID, isUnveiled: tile.isUnveiled,
                                        fogEdgeSpriteIndex: fogEdge))
        }

        var units = [FrameInfo.Unit]()
        var effects = [FrameInfo.Effect]()
        var blurs = [FrameInfo.Blur]()
        for u in state.units where u.o.flags.contains(.used) {
            // Hidden units (in transport, inside a structure, off-map) are never drawn by `viewport.c`;
            // drawing them leaves a phantom at the unit's stale position (e.g. a harvester frozen at its
            // pickup spot while the carryall flies off, or a carried harvester showing before the drop).
            if u.o.flags.contains(.isNotOnMap) { continue }
            guard let type = UnitType(rawValue: Int(u.o.type)) else { continue }
            // The harvesting overlay is gated on the harvester standing on a spice tile.
            let landscape = mapPrimitives.landscapeType(state.map[Int(u.o.position.packed)], tileIDs: state.tileIDs)
            let onSpice = landscape == .spice || landscape == .thickSpice
            guard let sprites = UnitSprites.info(for: u, onSpice: onSpice) else { continue }
            // A sandworm (`blurTile`) is not a normal SHP draw: the renderer displaces the terrain under
            // its silhouette (`DRAWSPRITE_FLAG_BLUR`). Carry it as a Blur — its body frame is the mask.
            if UnitInfo[type].o.flags.contains(.blurTile) {
                blurs.append(FrameInfo.Blur(positionX: Int(u.o.position.x), positionY: Int(u.o.position.y),
                                            sprite: sprites.body))
                continue
            }
            let house = HouseID(rawValue: Int(state.unitHouseID(u))) ?? .harkonnen
            let isSmoking = u.o.flags.contains(.isSmoking)
            units.append(FrameInfo.Unit(
                id: u.o.index, type: type, house: house,
                positionX: Int(u.o.position.x), positionY: Int(u.o.position.y),
                body: sprites.body, turret: sprites.turret, overlay: sprites.overlay, isSmoking: isSmoking,
                isAirUnit: UnitInfo[type].movementType == .winger,
                hitpoints: Int(u.o.hitpoints), hitpointsMax: Int(UnitInfo[type].o.hitpoints),
                activity: Self.activity(forActionID: u.actionID)))

            // Smoke cloud over a damaged-but-alive vehicle, 14px above the unit centre
            // (`viewport.c:615`): frame `180 + (spriteOffset & 3)`, with 183 folded back to 181.
            if isSmoking {
                var frame = 180 + (Int(u.spriteOffset) & 3)
                if frame == 183 { frame = 181 }
                effects.append(FrameInfo.Effect(
                    positionX: Int(u.o.position.x), positionY: Int(u.o.position.y),
                    sprite: SpriteLayer(spriteIndex: frame, offsetY: -14)))
            }
        }

        var structures = [FrameInfo.Structure]()
        for s in state.structures where s.o.flags.contains(.used) {
            guard let type = StructureType(rawValue: Int(s.o.type)) else { continue }
            let house = HouseID(rawValue: Int(s.o.houseID)) ?? .harkonnen
            structures.append(FrameInfo.Structure(
                id: s.o.index, type: type, house: house,
                positionX: Int(s.o.position.x), positionY: Int(s.o.position.y),
                hitpoints: Int(s.o.hitpoints), hitpointsMax: Int(s.hitpointsMax)))
        }

        // Active explosions (impacts / unit deaths / building destruction). `spriteID` is already a
        // global index; the sim advances it via `explosionTick`, the renderer just draws the frame.
        for explosion in state.explosions where explosion.active {
            effects.append(FrameInfo.Effect(
                positionX: Int(explosion.position.x), positionY: Int(explosion.position.y),
                sprite: SpriteLayer(spriteIndex: Int(explosion.spriteID))))
        }

        var houses = [FrameInfo.House]()
        for h in state.houses where h.flags.contains(.used) {
            guard let id = HouseID(rawValue: Int(h.index)) else { continue }
            houses.append(FrameInfo.House(
                id: id, credits: Int(h.credits), creditsStorage: Int(h.creditsStorage),
                powerProduction: Int(h.powerProduction), powerUsage: Int(h.powerUsage)))
        }

        return FrameInfo(
            tick: state.timerGame, mapWidth: width, mapHeight: height,
            tiles: tiles, units: units, structures: structures, effects: effects, houses: houses,
            viewportX: Int(Tile32.packedX(state.viewportPosition)) * 256,
            viewportY: Int(Tile32.packedY(state.viewportPosition)) * 256,
            veiledTileIndex: Int(state.tileIDs.veiled), blurs: blurs)
    }

    /// The 4-neighbour fog-of-war veil bitmask for tile `packed` on a `width × height` grid — bit 0 = N,
    /// 1 = E, 2 = S, 3 = W (`g_table_mapDiff = {-64, 1, 64, -1}`): a bit is set when that neighbour is
    /// off-map or still veiled. Mirrors `Map_UnveilTile_Neighbour` (`map.c:1311`); the result indexes the
    /// 16 fog-edge sprites (`TileIDs.fogEdges`). Mask 0 = fully surrounded by revealed tiles ⇒ no edge.
    /// Collapse a unit's `ActionType` (`actionID`) to the UI activity category for the state chip.
    static func activity(forActionID actionID: UInt8) -> FrameInfo.UnitActivity {
        switch ActionType(rawValue: Int(actionID)) {
            case .attack, .hunt, .ambush, .sabotage: return .attacking
            case .move, .retreat:                    return .moving
            case .guard_, .areaGuard:                return .guarding
            case .harvest, .return:                  return .harvesting
            default:                                  return .idle   // stop / deploy / die / destruct / none
        }
    }

    static func fogEdgeMask(packed: Int, width: Int, height: Int, isUnveiled: (Int) -> Bool) -> Int {
        let x = packed % width, y = packed / width
        var mask = 0
        if y == 0 || !isUnveiled(packed - width) { mask |= 1 << 0 }          // N
        if x == width - 1 || !isUnveiled(packed + 1) { mask |= 1 << 1 }      // E
        if y == height - 1 || !isUnveiled(packed + width) { mask |= 1 << 2 } // S
        if x == 0 || !isUnveiled(packed - 1) { mask |= 1 << 3 }              // W
        return mask
    }
}
