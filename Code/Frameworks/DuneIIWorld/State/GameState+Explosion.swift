/// The explosion engine — a faithful port of OpenDUNE's `src/explosion.c`. Explosions are the short
/// visual sprite animations played at a tile for impacts, unit deaths, and building destruction, driven
/// by a small command VM. Started by `Map_MakeExplosion` (`explosionStart`, RNG-free); advanced by
/// `explosionTick()` (which draws RNG and so is gated to the lab — see `Documentation/Algorithms/Explosion.md`).
public extension GameState {
    static let explosionMax = 32

    /// `Explosion_Start` (`explosion.c:282`): begin an explosion of `type` at `position`. Stops any
    /// explosion already on that tile, takes the first free slot, and arms it for immediate processing.
    /// Draws no RNG (golden-neutral; the oracle calls this in the scenario harness too).
    mutating func explosionStart(type: Int, position: Tile32, houseID: UInt8 = 0) {
        guard type >= 0, type < ExplosionType.max else { return }
        let packed = Int(position.packed)
        explosionStopAtPosition(position.packed)

        for i in explosions.indices where !explosions[i].active {
            var explosion = Explosion()
            explosion.tableIndex = type
            explosion.current = 0
            explosion.spriteID = 0
            explosion.position = position
            explosion.timeOut = timerGUI
            explosion.houseID = houseID
            explosion.active = true
            explosions[i] = explosion
            explosionTimer = 0
            map[packed].hasExplosion = true
            return
        }
    }

    /// `Explosion_StopAtPosition` (`explosion.c:252`): stop any explosion currently on `packed`.
    mutating func explosionStopAtPosition(_ packed: UInt16) {
        guard map[Int(packed)].hasExplosion else { return }
        for i in explosions.indices where explosions[i].active && explosions[i].position.packed == packed {
            explosionFuncStop(i)
            return
        }
    }

    /// `Explosion_Tick` (`explosion.c:318`): process every active explosion whose `timeOut` has arrived,
    /// executing one command each. Draws RNG via `SET_RANDOM_TIMEOUT` — so it is called only when
    /// `Simulation(tickExplosions:)` is set (the lab), never in the golden/oracle-matched path.
    mutating func explosionTick() {
        if explosionTimer > timerGUI { return }
        explosionTimer = explosionTimer &+ 10000

        for i in explosions.indices where explosions[i].active {
            if explosions[i].timeOut <= timerGUI {
                let row = ExplosionTables.commands[explosions[i].tableIndex]
                let cursor = Int(explosions[i].current)
                guard cursor < row.count else { explosionFuncStop(i); continue }
                let command = row[cursor]
                explosions[i].current = explosions[i].current &+ 1
                let parameter = command.parameter

                switch command.command {
                    case .stop:
                        explosionFuncStop(i)
                    case .setSprite:
                        explosions[i].spriteID = UInt16(truncatingIfNeeded: parameter)
                    case .setTimeout:
                        explosions[i].timeOut = timerGUI &+ UInt32(max(0, Int(parameter)))
                    case .setRandomTimeout:
                        explosions[i].timeOut = timerGUI &+ UInt32(randomLCG.range(0, UInt16(truncatingIfNeeded: parameter)))
                    case .moveYPosition:
                        explosions[i].position.y = UInt16(truncatingIfNeeded: Int(explosions[i].position.y) + Int(parameter))
                    case .tileDamage:
                        explosionTileDamage(explosions[i].position.packed)
                    case .playVoice:
                        emitSound(Int(parameter), at: explosions[i].position)   // Explosion_Func_PlayVoice
                    case .screenShake:
                        break   // SEAM: video
                    case .setAnimation:
                        break   // SEAM: g_table_animation_map (only the two crash explosions use it)
                    case .bloomExplosion:
                        // Explosion_Func_BloomExplosion (explosion.c:157): if the tile under the explosion is
                        // still the spice bloom, queue it for Map_Bloom_ExplodeSpice (a Simulation primitive,
                        // drained by the loop after explosionTick). This is the "shoot a bloom to pop it" path.
                        let bp = explosions[i].position.packed
                        if Int(bp) < map.count, map[Int(bp)].groundTileID == tileIDs.bloom {
                            pendingBloomDetonations.append(bp)
                        }
                }
                if !explosions[i].active { continue }
            }
            if explosions[i].timeOut <= explosionTimer { explosionTimer = explosions[i].timeOut }
        }
    }

    /// The landscape-changing part of `Explosion_Func_TileDamage` (`explosion.c:49`): a concrete **slab**
    /// under an explosion is blasted back to the seed base landscape tile (`g_mapTileID[packed]`) — built
    /// concrete plates ARE destructible. A structure tile (`LST_STRUCTURE`) or an already-destroyed wall
    /// (`LST_DESTROYED_WALL`) is left alone, and a veiled tile is untouched (`Map_IsPositionUnveiled`). The
    /// crater **overlay** + `Map_ChangeSpiceAmount` + bloom-explode (`Tools_Random_256`) on sand/rock are a
    /// SEAM — they need `Map_GetLandscapeType`'s full classification (a Simulation primitive) and only fire
    /// off-slab, so they are gated out of the slab-destruction path here.
    mutating func explosionTileDamage(_ packed: UInt16) {
        let pos = Int(packed)
        guard pos >= 0, pos < map.count, mapIsPositionUnveiled(pos) else { return }
        // Skip a structure tile (LST_STRUCTURE) or an already-destroyed wall (LST_DESTROYED_WALL).
        if map[pos].hasStructure { return }
        if UInt16(map[pos].overlayTileID) == tileIDs.wall { return }
        // A concrete slab is blasted back to the base landscape tile.
        if map[pos].groundTileID == tileIDs.builtSlab {
            map[pos].groundTileID = mapBaseTileID[pos]
            mapDirty = true
        }
        // SEAM: the crater overlay (+ Random_256), Map_ChangeSpiceAmount, and bloom-explode on sand/rock.
    }

    /// `Map_IsPositionUnveiled` (`map.c`): the tile is revealed and its overlay isn't the fog veil.
    private func mapIsPositionUnveiled(_ pos: Int) -> Bool {
        guard map[pos].isUnveiled else { return false }
        let o = UInt16(map[pos].overlayTileID)
        return o > tileIDs.veiled || o < tileIDs.veiled &- 15   // Tile_IsUnveiled
    }

    /// `Explosion_Func_Stop` (`explosion.c:205`): clear the tile's `hasExplosion` and free the slot.
    private mutating func explosionFuncStop(_ i: Int) {
        map[Int(explosions[i].position.packed)].hasExplosion = false
        explosions[i].active = false
        explosions[i].tableIndex = -1
    }
}
