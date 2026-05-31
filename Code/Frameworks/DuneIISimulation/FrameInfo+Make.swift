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
        for tile in state.map {
            tiles.append(FrameInfo.Tile(groundSpriteIndex: Int(tile.groundTileID),
                                        overlaySpriteIndex: Int(tile.overlayTileID),
                                        houseID: tile.houseID, isUnveiled: tile.isUnveiled))
        }

        var units = [FrameInfo.Unit]()
        var effects = [FrameInfo.Effect]()
        for u in state.units where u.o.flags.contains(.used) {
            guard let type = UnitType(rawValue: Int(u.o.type)) else { continue }
            // Sandworm shimmer (`blurTile`) is not a normal SHP draw — omit it.
            if UnitInfo[type].o.flags.contains(.blurTile) { continue }
            guard let sprites = UnitSprites.info(for: u) else { continue }
            let house = HouseID(rawValue: Int(state.unitHouseID(u))) ?? .harkonnen
            let isSmoking = u.o.flags.contains(.isSmoking)
            units.append(FrameInfo.Unit(
                id: u.o.index, type: type, house: house,
                positionX: Int(u.o.position.x), positionY: Int(u.o.position.y),
                body: sprites.body, turret: sprites.turret, isSmoking: isSmoking,
                hitpoints: Int(u.o.hitpoints), hitpointsMax: Int(UnitInfo[type].o.hitpoints)))

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
            viewportY: Int(Tile32.packedY(state.viewportPosition)) * 256)
    }
}
