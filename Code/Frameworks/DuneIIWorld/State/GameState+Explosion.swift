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
                        break   // SEAM: crater overlay + Map_ChangeSpiceAmount + bloom (+ Random_256); cosmetic, gated off for goldens
                    case .playVoice:
                        break   // SEAM: audio (Voice_PlayAtTile)
                    case .screenShake:
                        break   // SEAM: video
                    case .setAnimation:
                        break   // SEAM: g_table_animation_map (only the two crash explosions use it)
                    case .bloomExplosion:
                        break   // SEAM: Map_Bloom_ExplodeSpice
                }
                if !explosions[i].active { continue }
            }
            if explosions[i].timeOut <= explosionTimer { explosionTimer = explosions[i].timeOut }
        }
    }

    /// `Explosion_Func_Stop` (`explosion.c:205`): clear the tile's `hasExplosion` and free the slot.
    private mutating func explosionFuncStop(_ i: Int) {
        map[Int(explosions[i].position.packed)].hasExplosion = false
        explosions[i].active = false
        explosions[i].tableIndex = -1
    }
}
