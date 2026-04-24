import Foundation
import Memoirs

extension Scripting {
    /// Reference-typed wrapper around OpenDUNE's two PRNGs. A single
    /// instance is shared across every host-function closure that wants
    /// random numbers, matching OpenDUNE's one-global-stream model.
    public final class RandomSource: @unchecked Sendable {
        public var lcg: RNG.BorlandLCG
        public var tools: RNG.ToolsRandom256

        /// Parity-harness trace hook. When non-nil, `toolsNext()` logs
        /// every byte drawn from `tools` so a bit-exact diff against
        /// OpenDUNE's `Tools_Random_256` call stream can pinpoint
        /// RNG-sequence drift. Direct `source.tools.next()` callers
        /// bypass this hook — the parity harness routes its own
        /// `harvestRNG` closure through `toolsNext()` too.
        ///
        /// The `context` string is an optional free-form tag (e.g.
        /// unit pool index + function name) the scheduler/scripts can
        /// poke via `currentTraceContext` so the diff narrows to the
        /// exact call site, not just the byte position.
        public var onToolsDraw: ((UInt8, String) -> Void)?

        /// Per-call context tag. Scheduler / scripts set this right
        /// before they expect RNG draws so the trace records who
        /// asked. `""` when unknown.
        public var currentTraceContext: String = ""

        /// Draw a byte from `tools` with optional trace.
        public func toolsNext() -> UInt8 {
            let b = tools.next()
            onToolsDraw?(b, currentTraceContext)
            return b
        }

        public init(seed: UInt16) {
            self.lcg = RNG.BorlandLCG(seed: seed)
            self.tools = RNG.ToolsRandom256(seed: UInt32(seed))
        }

        public init(lcgSeed: UInt16, toolsSeed: UInt32) {
            self.lcg = RNG.BorlandLCG(seed: lcgSeed)
            self.tools = RNG.ToolsRandom256(seed: toolsSeed)
        }
    }

    /// First batch of generic `Script_General_*` host functions. Each entry
    /// mirrors OpenDUNE byte-for-byte (see `src/script/general.c`).
    /// Signatures follow the `VM.Function` typealias so they can be dropped
    /// straight into a 64-slot function table.
    public enum Functions {
        /// `Script_General_NoOperation` — returns 0, no stack effect.
        public static func noOperation(_ engine: inout Engine) -> UInt16 {
            return 0
        }

        /// `Script_General_Delay` — writes `engine.delay = peek(1) / 5` and
        /// returns the same value. Argument is **not** popped: the EMC
        /// compiler emits an explicit `STACK_REWIND` after the call.
        public static func delay(_ engine: inout Engine) -> UInt16 {
            let ticks = Scripting.peek(engine: &engine, position: 1)
            let d = ticks / 5
            engine.delay = d
            return d
        }

        /// Factory: closes over `source` to produce a `VM.Function` that
        /// mirrors `Script_General_RandomRange`. Draws from the shared LCG,
        /// so multiple call sites see OpenDUNE's one-stream behaviour.
        public static func makeRandomRange(source: RandomSource) -> VM.Function {
            return { engine in
                let lo = Scripting.peek(engine: &engine, position: 1)
                let hi = Scripting.peek(engine: &engine, position: 2)
                return source.lcg.range(lo, hi)
            }
        }

        // MARK: Batch 2 — host-context-aware functions

        /// `Script_General_DisplayText` — peek(1) is a text-table index;
        /// peek(2..4) are the three format arguments. Appends a
        /// `DisplayedText` to `host.textLog` and returns 0. Out-of-range
        /// text indices are silently dropped (we refuse to write something
        /// we can't look up).
        public static func makeDisplayText(host: Host) -> VM.Function {
            return { engine in
                let textIndex = Int(Scripting.peek(engine: &engine, position: 1))
                let arg1 = Scripting.peek(engine: &engine, position: 2)
                let arg2 = Scripting.peek(engine: &engine, position: 3)
                let arg3 = Scripting.peek(engine: &engine, position: 4)
                guard textIndex >= 0, textIndex < host.texts.count else { return 0 }
                host.textLog.append(Host.DisplayedText(
                    text: host.texts[textIndex],
                    arg1: arg1, arg2: arg2, arg3: arg3
                ))
                return 0
            }
        }

        /// `Script_General_UnitCount` — counts units matching
        /// `(host.currentObject.houseID, peek(1) = type)`. Returns 0 when
        /// no current object is set.
        public static func makeUnitCount(host: Host) -> VM.Function {
            return { engine in
                guard let houseID = host.currentHouseID else { return 0 }
                let type = UInt8(truncatingIfNeeded: Scripting.peek(engine: &engine, position: 1))
                var query = Simulation.PoolQuery(houseID: houseID, type: type)
                var count: UInt16 = 0
                while host.units.next(&query) != nil { count &+= 1 }
                return count
            }
        }

        /// `Script_General_GetOrientation` — decodes peek(1) as an encoded
        /// unit index and returns the slot's `orientationCurrent`. Returns
        /// `128` for non-unit / invalid / freed references (matches the
        /// OpenDUNE sentinel).
        public static func makeGetOrientation(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                guard let slot = host.unitSlot(for: encoded) else { return 128 }
                return UInt16(bitPattern: Int16(slot.orientationCurrent))
            }
        }

        /// `Script_General_IsEnemy` — returns `1` when the referenced
        /// object's house differs from `currentObject`'s, `0` otherwise
        /// (including invalid indices, per OpenDUNE).
        public static func makeIsEnemy(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                guard let currentHouse = host.currentHouseID else { return 0 }
                guard let targetHouse = host.houseID(of: encoded) else { return 0 }
                return targetHouse != currentHouse ? 1 : 0
            }
        }

        /// `Script_General_IsFriendly` — `1` friendly, `-1` (0xFFFF) enemy,
        /// `0` invalid. Pre-checks `used`/valid via the pool lookup, then
        /// defers the house-comparison to `IsEnemy`.
        public static func makeIsFriendly(host: Host) -> VM.Function {
            let isEnemy = makeIsEnemy(host: host)
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                switch encoded.kind {
                case .unit:
                    guard host.unitSlot(for: encoded) != nil else { return 0 }
                case .structure:
                    let idx = Int(encoded.decoded)
                    guard idx < host.structures.slots.count, host.structures.slots[idx].isUsed else { return 0 }
                case .none, .tile:
                    return 0
                }
                let enemyResult = isEnemy(&engine)
                return enemyResult == 0 ? 1 : 0xFFFF
            }
        }

        // MARK: Batch 3 — unit-specific generics

        /// `Script_Unit_GetInfo` (unit slot 0x00) — 20-way switch on the
        /// requested info field. Subcases that need `g_playerHouseID`
        /// (0x13 — seenByHouses bit) still return `0`; everything else
        /// is now covered via `Simulation.UnitInfo.lookup`.
        public static func makeGetInfoUnit(host: Host) -> VM.Function {
            return { engine in
                let which = Scripting.peek(engine: &engine, position: 1)
                guard let (_, slot) = currentUnit(host: host) else { return 0 }
                let info = Simulation.UnitInfo.lookup(slot.type)
                switch which {
                case 0x00:
                    // Hitpoints ratio (0..255). `u->o.hitpoints * 256 / ui->o.hitpoints`.
                    guard let info, info.hitpoints != 0 else { return 0 }
                    return UInt16(min(255, Int(slot.hitpoints) * 256 / Int(info.hitpoints)))
                case 0x01:
                    // `Tools_Index_IsValid(u->targetMove) ? u->targetMove : 0`
                    let encoded = Scripting.EncodedIndex(raw: slot.targetMove)
                    return isValid(encoded: encoded, host: host) ? slot.targetMove : 0
                case 0x02:
                    // `ui->fireDistance << 8` (tile-to-pixel scale).
                    return (info?.fireDistance ?? 0) &<< 8
                case 0x03:
                    return slot.index
                case 0x04:
                    return UInt16(bitPattern: Int16(slot.orientationCurrent))
                case 0x05:
                    return slot.targetAttack
                case 0x06:
                    // Bare return — OpenDUNE would auto-`Unit_FindClosestRefinery`
                    // when `originEncoded == 0 || type == HARVESTER`; deferred.
                    return slot.originEncoded
                case 0x07:
                    return UInt16(slot.type)
                case 0x08:
                    return Scripting.EncodedIndex.unit(slot.index).raw
                case 0x0B:
                    // `(u->currentDestination.x == 0 && u->currentDestination.y == 0) ? 0 : 1`
                    // — `currentDestination` is the pixel-level per-step goal
                    // the route-follower is walking toward RIGHT NOW.
                    // `targetMove` is the player's ultimate goal and is a
                    // different field; reading targetMove here made the MOVE
                    // handler (UNIT.EMC word 637) decide "already moving" on
                    // tick 1 of a fresh order and loop forever at the wait.
                    return (slot.currentDestinationX == 0 && slot.currentDestinationY == 0) ? 0 : 1
                case 0x0D:
                    // `ui->flags.explodeOnDeath`.
                    return (info?.explodeOnDeath ?? false) ? 1 : 0
                case 0x0E:
                    return UInt16(slot.houseID)
                case 0x10:
                    // Turret orientation — we don't separate turret from body
                    // yet, so return body orientation regardless.
                    return UInt16(bitPattern: Int16(slot.orientationCurrent))
                case 0x12:
                    // `(ui->movementType & 0x40) == 0 ? 0 : 1` — the 0x40 bit
                    // never appears in MovementType enum (all values < 6), so
                    // this is effectively always 0 in vanilla data.
                    return 0
                default:
                    return 0
                }
            }
        }

        /// `Script_Unit_SetAction` (unit slot 0x01) — writes `peek(1) & 0xFF`
        /// to the current unit's `actionID`. Always returns `0`. The
        /// player-side `ACTION_HARVEST` early-out and the richer
        /// `Unit_SetAction` side-effects are deferred.
        public static func makeSetActionUnit(host: Host) -> VM.Function {
            return { engine in
                let action = UInt8(truncatingIfNeeded: Scripting.peek(engine: &engine, position: 1))
                guard case .unit(let poolIndex)? = host.currentObject,
                      poolIndex >= 0, poolIndex < host.units.slots.count,
                      host.units.slots[poolIndex].isUsed else { return 0 }
                var slot = host.units.slots[poolIndex]
                let prior = slot.actionID
                slot.actionID = action
                host.units[poolIndex] = slot
                if prior != action {
                    Log.debug(
                        "SetAction unit \(poolIndex): \(prior) → \(action)",
                        tracer: .label("setaction")
                    )
                }
                return 0
            }
        }

        /// `Script_Unit_GetAmount` (unit slot 0x20) — returns `u->amount`,
        /// or the linked unit's `amount` when `u->linkedID != 0xFF` and the
        /// linked slot is live.
        public static func makeGetAmountUnit(host: Host) -> VM.Function {
            return { engine in
                guard let (_, slot) = currentUnit(host: host) else { return 0 }
                if slot.linkedID == 0xFF { return UInt16(slot.amount) }
                let linkedIndex = Int(slot.linkedID)
                guard linkedIndex < host.units.slots.count else { return UInt16(slot.amount) }
                let linked = host.units.slots[linkedIndex]
                guard linked.isUsed, linked.isAllocated else { return UInt16(slot.amount) }
                return UInt16(linked.amount)
            }
        }

        // MARK: Batch 6 — position-dependent generics

        /// `Script_General_GetDistanceToTile` — distance from the current
        /// object to the tile encoded in peek(1). `0xFFFF` when the
        /// reference is invalid.
        public static func makeGetDistanceToTile(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                guard let from = currentPosition(host: host) else { return 0xFFFF }
                guard let to = Pos32.of(encoded, host: host) else { return 0xFFFF }
                return Pos32.distance(from, to)
            }
        }

        /// `Script_General_GetDistanceToObject` — same metric; just a
        /// different name in OpenDUNE because the C overload takes a
        /// different path internally. At this layer they're identical.
        public static func makeGetDistanceToObject(host: Host) -> VM.Function {
            makeGetDistanceToTile(host: host)
        }

        /// `Script_General_VoicePlay` — queues a voice sample keyed on
        /// peek(1) at the current object's position. Appends to
        /// `host.voiceLog`.
        public static func makeVoicePlay(host: Host) -> VM.Function {
            return { engine in
                let voiceID = Scripting.peek(engine: &engine, position: 1)
                let pos = currentPosition(host: host) ?? Pos32(x: 0, y: 0)
                host.voiceLog.append(Host.VoicePlay(
                    voiceID: voiceID, positionX: pos.x, positionY: pos.y
                ))
                return 0
            }
        }

        // MARK: Batch 7 — simple unit mutators (no pathfinding / no combat)

        /// `Script_Unit_SetOrientation` (slot 0x07) — port of
        /// `src/script/unit.c:707..715`. Calls
        /// `Unit_SetOrientation(u, peek(1), rotateInstantly=false, 0)`
        /// which sets `orientationTarget` + seeds `orientationSpeed`
        /// for gradual rotation via `tickRotation`. Returns the unit's
        /// current orientation (advances over subsequent ticks).
        public static func makeSetOrientationUnit(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                Simulation.Units.setOrientation(
                    poolIndex: poolIndex,
                    orientation: Int8(truncatingIfNeeded: raw),
                    rotateInstantly: false, level: 0,
                    units: &host.units
                )
                return UInt16(bitPattern: Int16(host.units.slots[poolIndex].orientationCurrent))
            }
        }

        /// `Script_Unit_SetSpeed` — clamps peek(1) to 0..255, applies the
        /// `byScenario`-flag 192/256 down-scale (OpenDUNE `src/script/unit.c:388`),
        /// and routes through `Units.setSpeed` so `speed`, `speedPerTick`,
        /// `speedRemainder`, and `movingSpeed` are all set from the
        /// same input. Returns the 0..255 percent speed.
        public static func makeSetSpeedUnit(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                var speed = min(raw, 255)
                guard let (poolIndex, slot) = currentUnit(host: host) else { return 0 }
                if !slot.byScenario {
                    speed = (speed &* 192) / 256
                }
                Simulation.Units.setSpeed(
                    poolIndex: poolIndex,
                    speedPercent: speed,
                    units: &host.units,
                    gameSpeed: host.gameSpeed
                )
                return speed
            }
        }

        /// `Script_Unit_Stop` — sets speed to 0 through the same
        /// setSpeed pipeline so `speedPerTick` / `speedRemainder` reset
        /// cleanly.
        public static func makeStopUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                Simulation.Units.setSpeed(
                    poolIndex: poolIndex,
                    speedPercent: 0,
                    units: &host.units,
                    gameSpeed: host.gameSpeed
                )
                return 0
            }
        }

        /// `Script_Unit_Blink` — sets `blinkCounter = 32` (OpenDUNE's
        /// fixed 32-tick flash duration).
        public static func makeBlinkUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                var slot = host.units.slots[poolIndex]
                slot.blinkCounter = 32
                host.units[poolIndex] = slot
                return 0
            }
        }

        /// `Script_Unit_Die` — frees the unit slot. The full OpenDUNE
        /// behaviour (score / kill-counter updates, saboteur explosion)
        /// is deferred until the economy + explosion pool lands.
        public static func makeDieUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                host.units.free(at: poolIndex)
                return 0
            }
        }

        /// `Script_Unit_SetSprite` — writes `spriteOffset = -(peek(1) & 0xFF)`
        /// to nudge the idle animation sprite.
        public static func makeSetSpriteUnit(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                var slot = host.units.slots[poolIndex]
                slot.spriteOffset = Int8(truncatingIfNeeded: 0 &- Int16(raw & 0xFF))
                host.units[poolIndex] = slot
                return 0
            }
        }

        /// `Script_Unit_SetTarget` — port of `src/script/unit.c:834`.
        /// Writes peek(1) to `targetAttack`. For **non-turreted** units
        /// (infantry, trike, quad, etc.) also writes `targetMove = target`
        /// so the unit will walk toward its attack target; for turreted
        /// units (tank, siege, devastator) only the turret rotates. Both
        /// branches set the base orientation via `Unit_SetOrientation`
        /// (level 1 — turret). Returns the encoded target.
        public static func makeSetTargetUnit(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                let encoded = Scripting.EncodedIndex(raw: raw)
                guard let (poolIndex, slot) = currentUnit(host: host) else { return 0 }
                var updated = slot
                if raw == 0 || !isValid(encoded: encoded, host: host) {
                    updated.targetAttack = 0
                    host.units[poolIndex] = updated
                    return 0
                }
                updated.targetAttack = raw
                let hasTurret = Simulation.UnitInfo.lookup(slot.type)?.hasTurret ?? false
                if !hasTurret {
                    updated.targetMove = raw
                }
                host.units[poolIndex] = updated
                // OpenDUNE `src/script/unit.c:852..859` — compute the
                // direction from our pos to the target tile, then call
                // Unit_SetOrientation for level 0 (body, non-turret
                // units only) and level 1 (turret, always).
                // `rotateInstantly=false` seeds orientationTarget +
                // orientationSpeed; current advances via tickRotation.
                if let targetPos = Pos32.of(encoded, host: host) {
                    let fromPos = Pos32(x: updated.positionX, y: updated.positionY)
                    let orient = Int8(bitPattern: Pos32.direction(from: fromPos, to: targetPos))
                    if !hasTurret {
                        Simulation.Units.setOrientation(
                            poolIndex: poolIndex, orientation: orient,
                            rotateInstantly: false, level: 0, units: &host.units
                        )
                    }
                    Simulation.Units.setOrientation(
                        poolIndex: poolIndex, orientation: orient,
                        rotateInstantly: false, level: 1, units: &host.units
                    )
                }
                return raw
            }
        }

        /// `Script_Unit_Sandworm_GetBestTarget` (slot 0x36) — port of
        /// `src/script/unit.c:1883`. Returns the encoded unit index of
        /// the sandworm's best prey (highest `sandwormTargetPriority`),
        /// or 0. Distinct from the generic `FindBestTarget` because
        /// sandworms use a movement-weighted priority — wheeled >
        /// tracked ≈ harvester > foot.
        public static func makeSandwormGetBestTargetUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                if let bestIdx = Simulation.TargetAcquisition.sandwormFindBestTarget(
                    attackerIndex: poolIndex, host: host
                ) {
                    return Scripting.EncodedIndex.unit(UInt16(bestIdx)).raw
                }
                return 0
            }
        }

        /// `Script_Unit_ExplosionMultiple` (slot 0x12) — port of
        /// `src/script/unit.c:553`. Spawns one DEATH_HAND at the unit's
        /// centre with 25..50 damage, then seven more scattered via
        /// `Tile_MoveByRandom(unit.pos, radius, center: false)` at
        /// 75..150 damage each. Used by DEVASTATOR destruct + DEATH_HAND
        /// missile impact.
        public static func makeExplosionMultipleUnit(source: RandomSource, host: Host) -> VM.Function {
            return { engine in
                let radius = Scripting.peek(engine: &engine, position: 1)
                guard let (_, slot) = currentUnit(host: host) else { return 0 }
                let origin = Pos32(x: slot.positionX, y: slot.positionY)

                // First: central explosion with a lower damage roll.
                let centralDamage = source.lcg.range(25, 50)
                Simulation.Explosions.makeExplosion(
                    type: Simulation.ExplosionType.deathHand.rawValue,
                    position: origin, hitpoints: centralDamage,
                    unitOriginEncoded: 0, host: host
                )

                // Seven more at random drift.
                for _ in 0..<7 {
                    let scattered = Pos32.movedRandomly(
                        from: origin,
                        distance: radius,
                        center: false,
                        random: { source.toolsNext() }
                    )
                    let damage = source.lcg.range(75, 150)
                    Simulation.Explosions.makeExplosion(
                        type: Simulation.ExplosionType.deathHand.rawValue,
                        position: scattered, hitpoints: damage,
                        unitOriginEncoded: 0, host: host
                    )
                }
                return 0
            }
        }

        /// `Script_Unit_ExplosionSingle` (slot 0x0E) — port of
        /// `src/script/unit.c:533`. Detonates at the current unit's
        /// position with peek(1)-selected explosion type; damage radius
        /// is the unit's max HP (from UnitInfo). Attacker credit goes to
        /// `EncodedIndex.unit(shooter.index)`.
        public static func makeExplosionSingleUnit(host: Host) -> VM.Function {
            return { engine in
                let type = Scripting.peek(engine: &engine, position: 1)
                guard let (_, slot) = currentUnit(host: host) else { return 0 }
                guard let info = Simulation.UnitInfo.lookup(slot.type) else { return 0 }
                Simulation.Explosions.makeExplosion(
                    type: type,
                    position: Pos32(x: slot.positionX, y: slot.positionY),
                    hitpoints: info.hitpoints,
                    unitOriginEncoded: Scripting.EncodedIndex.unit(slot.index).raw,
                    host: host
                )
                return 0
            }
        }

        /// `Script_Unit_Fire` (slot 0x08) — port of `src/script/unit.c:577`.
        /// Launches a bullet at `currentUnit.targetAttack` when every
        /// fire gate passes: target valid, different from the unit's own
        /// tile (sandworm exception), `fireDelay == 0`, target in range,
        /// orientation within 8 units (skipped for wingers + sandworm).
        /// Resets `fireDelay` to `ui.fireDelay * 2` on success; toggles
        /// `fireTwiceFlip` with a 5-tick quick reload for `firesTwice`
        /// units. Returns 1 on success, 0 otherwise.
        ///
        /// Deferred (see `Fire.md` §6.1): sandworm eat branch,
        /// `Tools_AdjustToGameSpeed` scaling, `Unit_Deviation_Decrease`,
        /// voice + fog side-effects.
        ///
        /// **The trailing `fireDelay += Tools_Random_256() & 1`** at
        /// `src/script/unit.c:692` is consumed from the shared RNG
        /// stream on every successful fire — even a 0-bump affects the
        /// stream position. Needed for byte-level parity with OpenDUNE;
        /// every HUNT / ATTACK unit that fires draws this byte once.
        public static func makeFireUnit(host: Host, source: RandomSource) -> VM.Function {
            return { _ in
                guard let (shooterIdx, shooter) = currentUnit(host: host) else {
                    Log.debug("fire-gate no-current-object", tracer: .label("fire-gate"))
                    return 0
                }
                let target = shooter.targetAttack
                if target == 0 || !isValid(encoded: Scripting.EncodedIndex(raw: target), host: host) {
                    Log.debug(
                        "fire-gate unit=\(shooterIdx) invalid-target raw=\(String(format: "0x%04X", target))",
                        tracer: .label("fire-gate")
                    )
                    return 0
                }

                guard let info = Simulation.UnitInfo.lookup(shooter.type) else { return 0 }
                let isSandworm = shooter.type == 25

                // A unit aimed at its own tile self-cancels (sandworm
                // exception — worms eat whatever's under them).
                let ownPacked = Simulation.Pathfinder.packedTile(x: shooter.positionX, y: shooter.positionY)
                let ownTileEncoded = Scripting.EncodedIndex.tile(packed: ownPacked).raw
                var shooterSlot = shooter
                if !isSandworm && target == ownTileEncoded {
                    shooterSlot.targetAttack = 0
                    host.units[shooterIdx] = shooterSlot
                    Log.debug(
                        "fire-gate unit=\(shooterIdx) self-tile-cancel",
                        tracer: .label("fire-gate")
                    )
                    return 0
                }

                // Cooldown still running.
                if shooterSlot.fireDelay != 0 {
                    Log.debug(
                        "fire-gate unit=\(shooterIdx) cooldown fireDelay=\(shooterSlot.fireDelay)",
                        tracer: .label("fire-gate")
                    )
                    return 0
                }

                // Target in range.
                guard let targetPos = Pos32.of(Scripting.EncodedIndex(raw: target), host: host) else {
                    Log.debug(
                        "fire-gate unit=\(shooterIdx) target-pos-unresolved raw=\(String(format: "0x%04X", target))",
                        tracer: .label("fire-gate")
                    )
                    return 0
                }
                let shooterPos = Pos32(x: shooter.positionX, y: shooter.positionY)
                let distance = UInt32(Pos32.distance(shooterPos, targetPos))
                let fireRange = UInt32(info.fireDistance) &<< 8
                if Int32(bitPattern: fireRange) < Int32(bitPattern: distance) {
                    Log.debug(
                        "fire-gate unit=\(shooterIdx) out-of-range distance=\(distance) fireRange=\(fireRange) fireDistance=\(info.fireDistance)",
                        tracer: .label("fire-gate")
                    )
                    return 0
                }

                // Orientation gate — skip for sandworm and for winger targets.
                let targetEncoded = Scripting.EncodedIndex(raw: target)
                var targetIsWinger = false
                if targetEncoded.kind == .unit,
                   let tSlot = host.unitSlot(for: targetEncoded),
                   Simulation.UnitInfo.lookup(tSlot.type)?.movementType == .winger {
                    targetIsWinger = true
                }
                if !isSandworm && !targetIsWinger {
                    let dir = Pos32.direction(from: shooterPos, to: targetPos)
                    let current = Int16(shooter.orientationCurrent)
                    let desired = Int16(Int8(bitPattern: dir))
                    var diff = abs(current - desired)
                    if info.movementType == .winger { diff /= 8 }
                    if diff >= 8 {
                        Log.debug(
                            "fire-gate unit=\(shooterIdx) off-orientation current=\(current) desired=\(desired) diff=\(diff)",
                            tracer: .label("fire-gate")
                        )
                        return 0
                    }
                }

                var damage = info.damage
                var bulletType = info.bulletType ?? 0xFF
                let fireTwice = info.firesTwice
                    && shooter.hitpoints > info.hitpoints / 2

                // Long-range trooper substitution.
                if (shooter.type == 3 || shooter.type == 5) && distance > 512 {
                    bulletType = 22 // MISSILE_TROOPER
                    // MISSILE_TROOPER damage reduced by 25% (from OpenDUNE).
                    damage = damage &- damage / 4
                }

                switch bulletType {
                case 23, 24, 19, 20, 21, 18, 22:
                    // Bullet / sonic blast / missile family.
                    guard let bulletIdx = Simulation.Units.createBullet(
                        position: shooterPos,
                        type: bulletType,
                        houseID: shooter.houseID,
                        damage: damage,
                        target: target,
                        host: host
                    ) else {
                        Log.warning(
                            "fire: unit \(shooterIdx) createBullet(type=\(bulletType)) failed (pool full?)",
                            tracer: .label("fire")
                        )
                        return 0
                    }
                    var bullet = host.units[bulletIdx]
                    bullet.originEncoded = Scripting.EncodedIndex.unit(shooter.index).raw
                    host.units[bulletIdx] = bullet
                    // Muzzle flash — cosmetic `IMPACT_SMALL` with 0
                    // damage at the shooter's tile. OpenDUNE plays a
                    // voice cue (`Voice_PlayAtTile(ui->bulletSound)`)
                    // here; we render a visual instead so the player
                    // gets an unambiguous "this unit just fired" cue
                    // while the bullet flies toward its target.
                    Simulation.Explosions.makeExplosion(
                        type: Simulation.ExplosionType.impactSmall.rawValue,
                        position: shooterPos,
                        hitpoints: 0,
                        unitOriginEncoded: Scripting.EncodedIndex.unit(shooter.index).raw,
                        host: host
                    )
                    Log.info(
                        "fire: unit \(shooterIdx) (type \(shooter.type)) → bullet slot \(bulletIdx) (type \(bulletType)) target=\(String(format: "0x%04X", target)) damage=\(damage)",
                        tracer: .label("fire")
                    )

                case 25:
                    // Sandworm eat — deferred until the explosion pool
                    // lands. Bail rather than apply the cooldown; the
                    // sandworm will retry next script slice.
                    return 0

                default:
                    // UNIT_INVALID (carryall, harvester, etc.) — nothing
                    // to fire.
                    return 0
                }

                // Cooldown: normal reload OR firesTwice quick-reload.
                // Port of `src/script/unit.c:683..690`:
                //   u->fireDelay = Tools_AdjustToGameSpeed(ui->fireDelay * 2, 1, 0xFFFF, true);
                //   if (fireTwice) {
                //       u->o.flags.s.fireTwiceFlip = !u->o.flags.s.fireTwiceFlip;
                //       if (u->o.flags.s.fireTwiceFlip) u->fireDelay = Tools_AdjustToGameSpeed(5, 1, 10, true);
                //   } else u->o.flags.s.fireTwiceFlip = false;
                // `inverseSpeed=true` is load-bearing — `ui->fireDelay * 2`
                // is the SLOWEST cooldown, scaled DOWN at faster game
                // speeds (Tools_AdjustToGameSpeed inverts the bucket).
                let normalCooldown = Simulation.Tools.adjustToGameSpeed(
                    normal: UInt16(info.fireDelay) &* 2,
                    minimum: 1, maximum: 0xFFFF,
                    inverseSpeed: true, gameSpeed: host.gameSpeed
                )
                if fireTwice {
                    shooterSlot.fireTwiceFlip.toggle()
                    if shooterSlot.fireTwiceFlip {
                        let quick = Simulation.Tools.adjustToGameSpeed(
                            normal: 5, minimum: 1, maximum: 10,
                            inverseSpeed: true, gameSpeed: host.gameSpeed
                        )
                        shooterSlot.fireDelay = UInt8(clamping: quick)
                    } else {
                        shooterSlot.fireDelay = UInt8(clamping: normalCooldown)
                    }
                } else {
                    shooterSlot.fireTwiceFlip = false
                    shooterSlot.fireDelay = UInt8(clamping: normalCooldown)
                }
                // `u->fireDelay += Tools_Random_256() & 1` — port of
                // `src/script/unit.c:692`. Bumps fireDelay by 0 or 1
                // (roughly 50/50) every successful fire. Load-bearing
                // for RNG-stream parity: without this draw, the
                // shared Tools stream stays 1 byte behind OpenDUNE
                // every time a HUNT / ATTACK unit fires, cascading
                // into downstream script RNG offsets.
                source.currentTraceContext = "Fire.jitter u\(shooterIdx)"
                shooterSlot.fireDelay = shooterSlot.fireDelay &+ (source.toolsNext() & 1)
                source.currentTraceContext = ""
                host.units[shooterIdx] = shooterSlot
                return 1
            }
        }

        /// `Script_Unit_Rotate` (slot 0x3D) — port of `src/script/unit.c:726`.
        /// Rotates the unit (or turret) toward its `targetAttack`.
        ///
        /// - Non-wingers that are still moving (`currentDestination != 0`)
        ///   return 1 (wait until arrival).
        /// - If the relevant orientation track's `speed != 0` the unit is
        ///   already rotating → return 1.
        /// - If `targetAttack` is not a valid encoded index → return 0.
        /// - Computes `Tile_GetDirection(position → target)`. If already
        ///   aligned → return 0. Otherwise calls `Unit_SetOrientation` and
        ///   returns 1.
        public static func makeRotateUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (idx, slot) = currentUnit(host: host) else { return 0 }
                guard let info = Simulation.UnitInfo.lookup(slot.type) else { return 0 }

                // Non-winger mid-step: finish moving first.
                if info.movementType != .winger,
                   slot.currentDestinationX != 0 || slot.currentDestinationY != 0 {
                    return 1
                }

                let useTurret = info.hasTurret
                let speed: Int8 = useTurret ? slot.turretOrientationSpeed : slot.orientationSpeed
                if speed != 0 { return 1 }

                let current: Int8 = useTurret ? slot.turretOrientationCurrent : slot.orientationCurrent

                let encoded = Scripting.EncodedIndex(raw: slot.targetAttack)
                guard isValid(encoded: encoded, host: host) else { return 0 }
                guard let targetPos = Pos32.of(encoded, host: host) else { return 0 }

                let fromPos = Pos32(x: slot.positionX, y: slot.positionY)
                let orientation = Int8(bitPattern: Pos32.direction(from: fromPos, to: targetPos))

                if orientation == current { return 0 }

                let level: UInt16 = useTurret ? 1 : 0
                Simulation.Units.setOrientation(
                    poolIndex: idx, orientation: orientation,
                    rotateInstantly: false, level: level, units: &host.units
                )
                return 1
            }
        }

        /// `Script_Unit_FindBestTarget` (slot 0x1C) — wraps
        /// `Simulation.TargetAcquisition.findBestTargetEncoded` with the
        /// current unit as the attacker. Returns `0` when no current
        /// unit or no suitable target. Peek(1) is the mode.
        public static func makeFindBestTargetUnit(host: Host) -> VM.Function {
            return { engine in
                let mode = Scripting.peek(engine: &engine, position: 1)
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                let encoded = Simulation.TargetAcquisition.findBestTargetEncoded(
                    attackerIndex: poolIndex, mode: mode, host: host
                )
                Log.debug(
                    "FindBestTarget unit \(poolIndex) mode=\(mode) → \(String(format: "0x%04X", encoded))",
                    tracer: .label("target")
                )
                return encoded
            }
        }

        /// `Script_Unit_GetTargetPriority` (slot 0x1D) — computes the
        /// current unit's priority for the encoded target in peek(1).
        /// Unit targets → `targetUnitPriority`; structure targets →
        /// `targetStructurePriority`; everything else → `0`.
        public static func makeGetTargetPriorityUnit(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                guard let (_, attacker) = currentUnit(host: host) else { return 0 }
                switch encoded.kind {
                case .unit:
                    let idx = Int(encoded.decoded)
                    guard idx < host.units.slots.count else { return 0 }
                    let target = host.units.slots[idx]
                    guard target.isUsed, target.isAllocated else { return 0 }
                    return Simulation.TargetAcquisition.targetUnitPriority(
                        attacker: attacker, target: target, host: host
                    )
                case .structure:
                    let idx = Int(encoded.decoded)
                    guard idx < host.structures.slots.count else { return 0 }
                    let target = host.structures.slots[idx]
                    guard target.isUsed else { return 0 }
                    return Simulation.TargetAcquisition.targetStructurePriority(
                        attacker: attacker, target: target, host: host
                    )
                case .none, .tile:
                    return 0
                }
            }
        }

        /// `Script_Unit_IsInTransport` — `1` when the current unit's
        /// `inTransport` flag is set, `0` otherwise.
        public static func makeIsInTransportUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (_, slot) = currentUnit(host: host) else { return 0 }
                return slot.inTransport ? 1 : 0
            }
        }

        /// `Script_Unit_IdleAction` (slot 0x31) — port of OpenDUNE
        /// `src/script/unit.c:1748`. Ground units fidget while idle:
        /// foot units occasionally nudge their `spriteOffset`, and all
        /// three ground movement types (foot / tracked / wheeled) have a
        /// small chance of rotating to a random orientation each tick.
        /// Wingers / harvesters / sandworms skip the whole routine.
        public static func makeIdleActionUnit(source: RandomSource, host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, slot) = currentUnit(host: host) else { return 0 }
                Log.debug(
                    "IdleAction fired for unit \(poolIndex) type=\(slot.type) orient=\(slot.orientationCurrent)",
                    tracer: .label("idle")
                )
                guard let info = Simulation.UnitInfo.lookup(slot.type) else { return 0 }
                let mt = info.movementType
                guard mt == .foot || mt == .tracked || mt == .wheeled else { return 0 }

                let random = source.lcg.range(0, 10)
                var updated = slot

                // Foot units occasionally randomise sprite-offset.
                if mt == .foot && random > 8 {
                    source.currentTraceContext = "IdleAction.sprite u\(poolIndex)"
                    let spriteRaw = source.toolsNext()
                    source.currentTraceContext = ""
                    updated.spriteOffset = Int8(bitPattern: spriteRaw & 0x3F)
                }

                if random > 2 {
                    host.units[poolIndex] = updated
                    return 0
                }

                // OpenDUNE: `i = (Tools_Random_256() & 1) == 0 ? 1 : 0;`
                // then `Unit_SetOrientation(u, Tools_Random_256(), false, i)`.
                // `i == 0` writes the body orientation; `i == 1` writes
                // the turret. For units without a turret (foot /
                // non-turret wheeled), `i == 1` is a no-op, so body
                // orientation only changes ~50% of the calls. Our port
                // had dropped that distinction and rotated the body
                // every call, which made trikes / soldiers visibly
                // "blink" (sprite-flip toggles across octant boundaries)
                // while guarding.
                // OpenDUNE draws two RNG bytes unconditionally — consume
                // them here regardless of whether we apply the rotation
                // so the RNG sequence stays in lockstep.
                source.currentTraceContext = "IdleAction.turret u\(poolIndex)"
                let turretByte = source.toolsNext()
                source.currentTraceContext = "IdleAction.newOrient u\(poolIndex)"
                _ = source.toolsNext()  // newOrientation (target).
                source.currentTraceContext = ""
                let i: UInt8 = (turretByte & 1) == 0 ? 1 : 0
                _ = i
                // OpenDUNE calls `Unit_SetOrientation(u, newOrientation,
                // rotateInstantly=false, i)` which writes
                // `orientation[i].target + .speed` and lets `tickRotation`
                // advance `.current` gradually over subsequent ticks.
                // We don't yet track `target` / `speed` on `UnitSlot`
                // (see `ParityHarness.compareUnit` skip-list), so writing
                // `orientationCurrent` directly — as we used to — produced
                // tick-1 divergence (SAVE007 unit[36].orientation0Current).
                // Gameplay-visible effect: idle units no longer randomly
                // swing to a new heading each tick; they stay put until
                // target/speed + rotation-tick are ported.
                host.units[poolIndex] = updated
                return 0
            }
        }

        /// `Script_Unit_SetActionDefault` (slot 0x0A). Port of
        /// `src/script/unit.c:896` — reads `actionsPlayer[3]` off the
        /// unit's `UnitInfo` and writes it to the slot. `actionsPlayer[3]`
        /// is the fall-through action after a player-commanded move
        /// finishes (typically `guard_` for ground combat units).
        ///
        /// We collapse OpenDUNE's `Unit_SetAction` switchType=0 tail
        /// into a direct field write + `currentDestination` clear. The
        /// scheduler's per-slot `loadedUnitAction` delta-check reloads
        /// the engine at the new action on the next tick; OpenDUNE's
        /// explicit `Script_Reset` + `Script_Load` call falls out of
        /// that mechanism.
        public static func makeSetActionDefaultUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, slot) = currentUnit(host: host) else { return 0 }
                guard let info = Simulation.UnitInfo.lookup(slot.type) else { return 0 }
                var updated = slot
                updated.actionID = info.actionsPlayer[3]
                updated.currentDestinationX = 0
                updated.currentDestinationY = 0
                host.units[poolIndex] = updated
                Log.debug(
                    "SetActionDefault unit \(poolIndex) type=\(slot.type) → action \(info.actionsPlayer[3])",
                    tracer: .label("action")
                )
                return 0
            }
        }

        /// `Script_Unit_SetDestination` — writes `peek(1)` to `targetMove`
        /// if it's a valid encoded index, else clears it. The harvester-
        /// specific refinery-busy check (OpenDUNE `src/script/unit.c:809`)
        /// is deferred until the economy lands.
        public static func makeSetDestinationUnit(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                let encoded = Scripting.EncodedIndex(raw: raw)
                guard let (poolIndex, _) = currentUnit(host: host) else { return 0 }
                var slot = host.units.slots[poolIndex]
                if raw == 0 || !isValid(encoded: encoded, host: host) {
                    slot.targetMove = 0
                } else {
                    slot.targetMove = raw
                }
                host.units[poolIndex] = slot
                Log.debug(
                    "SetDestination unit \(poolIndex) → \(String(format: "0x%04X", raw)) (valid=\(slot.targetMove != 0))",
                    tracer: .label("dest")
                )
                return 0
            }
        }

        /// `Script_Unit_CalculateRoute` (slot 0x0C) — ports the OpenDUNE
        /// routine at `src/script/unit.c:1296`. Runs `Pathfinder.findRoute`
        /// when `u.route[0] == 0xFF`, copies up to 14 steps into
        /// `UnitSlot.route`, sets orientation to `route[0] * 32` when the
        /// first step isn't aligned to the body, and consumes the first
        /// step by memmove-left on success. Returns 1 while the route is
        /// not yet walked to completion, 0 on arrival / no-route.
        public static func makeCalculateRouteUnit(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.peek(engine: &engine, position: 1)
                guard let (poolIndex, slot) = currentUnit(host: host) else { return 1 }
                guard slot.targetMove == 0 || isValid(encoded: Scripting.EncodedIndex(raw: slot.targetMove), host: host) else {
                    return 1
                }

                // OpenDUNE `src/script/unit.c:1306` early-returns 1 when
                // the unit is mid-step (currentDestination already set)
                // OR the encoded destination is invalid. Without this,
                // mid-step units (e.g. SAVE007 u36 gliding north with
                // currentDest=(8320,7552) and route[0]=7 queued) get
                // their orientation reassigned to `route[0] * 32` every
                // call — diverging us from OpenDUNE's tick-1 state.
                if slot.currentDestinationX != 0 || slot.currentDestinationY != 0 {
                    return 1
                }
                if !isValid(encoded: Scripting.EncodedIndex(raw: encoded), host: host) {
                    return 1
                }

                let src = Simulation.Pathfinder.packedTile(x: slot.positionX, y: slot.positionY)
                let dstEncoded = Scripting.EncodedIndex(raw: encoded)
                guard let dstPos = Pos32.of(dstEncoded, host: host) else { return 1 }
                let dst = Simulation.Pathfinder.packedTile(x: dstPos.x, y: dstPos.y)

                var updated = slot
                if dst == src {
                    updated.route[0] = 0xFF
                    updated.targetMove = 0
                    host.units[poolIndex] = updated
                    Log.debug(
                        "CalculateRoute u\(poolIndex) src==dst tile=(\(src & 0x3F),\((src >> 6) & 0x3F)) — clearing targetMove",
                        tracer: .label("route")
                    )
                    return 0
                }

                if updated.route[0] == 0xFF {
                    // Fill a fresh route.
                    let movement = Simulation.UnitInfo.lookup(slot.type)?.movementType ?? .tracked
                    let scorer = host.tileEnterScore
                    // Capture for the closure: we need the attacker's
                    // pool index so we skip its own tile when checking
                    // unit-occupancy, and the unit pool snapshot so
                    // the closure can scan peers cheaply.
                    let selfIndex = poolIndex
                    let unitsSnapshot = host.units
                    let canCrushFoot = movement == .tracked || movement == .harvester
                    let scoreFn: Simulation.Pathfinder.TileEnterScore = { packed, orient in
                        // Unit-occupancy gate — port of OpenDUNE's
                        // `Unit_GetTileEnterScore` (src/unit.c:2335..2355).
                        // Tiles occupied by another unit are impassable
                        // EXCEPT that tracked / harvester movers may
                        // enter foot-occupied tiles (crush).
                        // Skips the mover itself; skips projectiles
                        // and wingers (they don't block ground).
                        let tx = Int(packed & 0x3F)
                        let ty = Int((packed >> 6) & 0x3F)
                        for (i, u) in unitsSnapshot.slots.enumerated() {
                            if i == selfIndex { continue }
                            guard u.isUsed else { continue }
                            if Simulation.Scheduler.isProjectileType(u.type) { continue }
                            let occupantMT = Simulation.UnitInfo.lookup(u.type)?.movementType
                            if occupantMT == .winger { continue }
                            if occupantMT == .foot, canCrushFoot { continue }
                            let utx = Int(u.positionX) / 256
                            let uty = Int(u.positionY) / 256
                            if utx == tx && uty == ty { return 256 }
                        }
                        if let fn = scorer { return fn(packed, orient, movement) }
                        // Fallback: always walkable with cost 128. Keeps the
                        // pathfinder productive for tests that don't wire a
                        // scorer and for live sessions until the map-backed
                        // scorer lands in `ScenarioScene`.
                        return 128
                    }
                    let found = Simulation.Pathfinder.findRoute(src: src, dst: dst, bufferSize: 40, score: scoreFn)
                    let copyCount = min(found.size, 14)
                    for i in 0..<14 {
                        updated.route[i] = i < copyCount ? found.buffer[i] : 0xFF
                    }
                    if updated.route[0] == 0xFF {
                        updated.targetMove = 0
                        Log.info(
                            "CalculateRoute u\(poolIndex) NO ROUTE from tile=(\(src & 0x3F),\((src >> 6) & 0x3F)) to tile=(\(dst & 0x3F),\((dst >> 6) & 0x3F)) — clearing targetMove",
                            tracer: .label("route")
                        )
                    } else {
                        let steps = updated.route.prefix(Int(copyCount)).map(String.init).joined(separator: ",")
                        Log.info(
                            "CalculateRoute u\(poolIndex) filled route len=\(copyCount) from tile=(\(src & 0x3F),\((src >> 6) & 0x3F)) to tile=(\(dst & 0x3F),\((dst >> 6) & 0x3F)) steps=[\(steps)]",
                            tracer: .label("route")
                        )
                    }
                } else {
                    // `route[0] != 0xFF` — we already have a partial route.
                    // OpenDUNE truncates when we're close enough; match that.
                    let distance = Simulation.Pathfinder.packedDistance(from: src, to: dst)
                    if distance < 14 {
                        updated.route[Int(distance)] = 0xFF
                        Log.debug(
                            "CalculateRoute u\(poolIndex) truncating partial route at distance=\(distance)",
                            tracer: .label("route")
                        )
                    }
                }

                if updated.route[0] == 0xFF {
                    host.units[poolIndex] = updated
                    return 1
                }

                // Port the SetSpeed slice of `Unit_StartMovement`
                // (`src/unit.c:1088..1105`): look up the landscape at
                // the tile we're about to enter, read
                // `movementSpeed[type]`, reduce by 1/4 if HP<half for
                // non-winger units, then route through
                // `Units.setSpeed` so `speedPerTick` + `speedRemainder`
                // are set correctly — the scheduler's subpixel tick
                // reads them to drive `Tile_MoveByDirection`.
                //
                // Runs BEFORE the orientation-gated early return so a
                // newly-filled route sets speed immediately. Previously
                // this lived after the orientation check, but the UNIT.EMC
                // MOVE handler hits the "already moving" wait once
                // `currentDestination` populates, which blocks any second
                // CalcRoute call — leaving `speed = 0` forever.
                if let landscapeAt = host.landscapeAt,
                   let info = Simulation.UnitInfo.lookup(slot.type) {
                    let stepDir = Int(updated.route[0])
                    let delta = Simulation.Pathfinder.mapDirection[stepDir]
                    let currentPacked = Simulation.Pathfinder.packedTile(
                        x: updated.positionX, y: updated.positionY
                    )
                    let nextPacked = UInt16(truncatingIfNeeded: Int32(currentPacked) + delta)
                    let lst = landscapeAt(nextPacked)
                    let landscapeIndex = Int(lst)
                    if landscapeIndex >= 0, landscapeIndex < Simulation.LandscapeInfo.table.count {
                        let land = Simulation.LandscapeInfo.table[landscapeIndex]
                        let mIndex = Int(info.movementType.rawValue)
                        if mIndex < land.movementSpeed.count {
                            // Port of `Unit_StartMovement`'s speed block
                            // at `src/unit.c:1095..1106`:
                            //   speed = g_table_landscapeInfo[type].movementSpeed[ui->movementType];
                            //   if ((ui->o.hitpoints / 2) > unit->o.hitpoints
                            //       && ui->movementType != MOVEMENT_WINGER)
                            //     speed -= speed / 4;
                            //   Unit_SetSpeed(unit, speed);
                            // The `byScenario * 192/256` scaling is a
                            // `Script_Unit_SetSpeed`-only concern
                            // (`src/script/unit.c:388`); Unit_StartMovement
                            // passes `speed` straight through.
                            var speed = UInt16(land.movementSpeed[mIndex])
                            if info.movementType != .winger,
                               (UInt16(info.hitpoints) / 2) > UInt16(updated.hitpoints) {
                                speed &-= speed / 4
                            }
                            // Write updated slot before setSpeed so it
                            // sees the current HP / amount.
                            host.units[poolIndex] = updated
                            Simulation.Units.setSpeed(
                                poolIndex: poolIndex,
                                speedPercent: speed,
                                units: &host.units,
                                gameSpeed: host.gameSpeed
                            )
                            updated = host.units[poolIndex]
                        }
                    }
                }

                // Orientation gate: if the unit hasn't rotated to face
                // the next step yet, set the target orientation and
                // return without consuming the step. Speed was already
                // written above so `tickMovement` can inch the unit
                // while the turret rotates (matches OpenDUNE's
                // `Unit_StartMovement` ordering).
                let desired = Int8(bitPattern: UInt8(updated.route[0] &* 32))
                if updated.orientationCurrent != desired {
                    updated.orientationCurrent = desired
                    host.units[poolIndex] = updated
                    return 1
                }

                // Port of Unit_StartMovement's currentDestination write
                // (`src/unit.c:1118`):
                //   unit->currentDestination = position;
                // where `position = Tile_MoveByOrientation(o.position,
                // orientation)`. With orientation octant-snapped to
                // `route[0] * 32`, Tile_MoveByOrientation steps by
                // exactly 256 pos32 pixels along the octant — not the
                // sin-approx step that `Pos32.moved` uses. Use the
                // matching `Pos32.movedByOrientation` helper.
                let stepOrient = UInt8(updated.route[0] &* 32)
                let fromPos = Pos32(x: updated.positionX, y: updated.positionY)
                let nextCenter = Pos32.movedByOrientation(fromPos, orientation: stepOrient)
                updated.currentDestinationX = nextCenter.x
                updated.currentDestinationY = nextCenter.y
                // Port of `Unit_StartMovement` (`src/unit.c:1082`):
                // `unit->distanceToDestination = 0x7FFF`. Prevents the
                // first movement tick after starting a route step from
                // falsely triggering the `distanceToDestination < newDist`
                // overshoot-arrival branch.
                updated.distanceToDestination = 0x7FFF

                // Consume one step (memmove route[1..] down by one). The
                // scheduler's `tickMovement` advances per-tile position
                // using the speed we just wrote.
                for i in 0..<13 { updated.route[i] = updated.route[i + 1] }
                updated.route[13] = 0xFF
                host.units[poolIndex] = updated
                return 1
            }
        }

        /// `Script_Unit_MoveToTarget` (slot 0x16) — OpenDUNE closes on
        /// `u->targetMove` smoothly, slowing near arrival. Ours runs the
        /// naive-distance check against `targetMove`: returns 1 when
        /// arrived (within 32 px, the scheduler threshold), 0 otherwise.
        /// Motion itself is handled by the scheduler's route-follower.
        public static func makeMoveToTargetUnit(host: Host) -> VM.Function {
            return { _ in
                guard let (_, slot) = currentUnit(host: host) else { return 0 }
                if slot.targetMove == 0 { return 0 }
                guard let dst = Pos32.of(Scripting.EncodedIndex(raw: slot.targetMove), host: host) else {
                    return 0
                }
                let dx = Int32(dst.x) - Int32(slot.positionX)
                let dy = Int32(dst.y) - Int32(slot.positionY)
                let distance = abs(dx) + abs(dy)
                return distance < 32 ? 1 : 0
            }
        }

        /// `Script_Unit_SetDestinationDirect` — snaps `targetMove` to an
        /// encoded tile and immediately faces it. Used by carryalls to
        /// bypass pathfinding. Nothing happens for invalid encoded input.
        public static func makeSetDestinationDirectUnit(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                let encoded = Scripting.EncodedIndex(raw: raw)
                guard isValid(encoded: encoded, host: host),
                      let (poolIndex, slot) = currentUnit(host: host),
                      let tgt = Pos32.of(encoded, host: host) else { return 0 }
                var updated = slot
                updated.targetMove = raw
                let from = Pos32(x: slot.positionX, y: slot.positionY)
                updated.orientationCurrent = Int8(bitPattern: Pos32.direction(from: from, to: tgt))
                host.units[poolIndex] = updated
                return 0
            }
        }

        // MARK: Batch 8 — structure combat

        /// `Script_Structure_FindTargetUnit` (structure slot 0x08) — port
        /// of `src/script/structure.c:303`. Walks `host.units` for the
        /// closest non-allied unit within `peek(1) * 256`-unit range and
        /// returns its encoded index, or 0. Ornithopters are allowed at
        /// 3× the stated range (AA-style lead). Skips unseen ground
        /// units (airborne units are always visible).
        public static func makeFindTargetUnitStructure(host: Host) -> VM.Function {
            return { engine in
                let targetRange = UInt32(Scripting.peek(engine: &engine, position: 1))
                guard let (_, s) = currentStructure(host: host) else { return 0 }
                let sPos = Pos32(x: s.positionX, y: s.positionY)

                var best: Simulation.UnitSlot?
                var bestDistance: UInt32 = 32000

                var query = Simulation.PoolQuery()
                while let u = host.units.next(&query) {
                    if Simulation.House.areAllied(s.houseID, u.houseID, playerHouseID: host.playerHouseID) {
                        continue
                    }
                    // Ornithopters (type 1) are always visible.
                    if u.type != 1 && (u.seenByHouses & (UInt8(1) &<< s.houseID)) == 0 {
                        continue
                    }
                    let d = UInt32(Pos32.distance(sPos, Pos32(x: u.positionX, y: u.positionY)))
                    if d >= bestDistance { continue }
                    // Range gate — wider for airborne targets.
                    let limit = (u.type == 1) ? targetRange &* 3 : targetRange
                    if d > limit { continue }

                    bestDistance = d
                    best = u
                }

                guard let best else { return 0 }
                return Scripting.EncodedIndex.unit(best.index).raw
            }
        }

        /// `Script_Structure_RotateTurret` (structure slot 0x09) — port
        /// of `src/script/structure.c:375`. Steps the turret's 8-way
        /// rotation one slot toward the orientation of the encoded
        /// target tile. Returns 0 when already aligned, 1 while
        /// rotating.
        public static func makeRotateTurretStructure(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.peek(engine: &engine, position: 1)
                if encoded == 0 { return 0 }
                guard let (poolIndex, s) = currentStructure(host: host) else { return 0 }
                let eidx = Scripting.EncodedIndex(raw: encoded)
                guard let lookAt = Pos32.of(eidx, host: host) else { return 0 }

                let from = Pos32(x: s.positionX, y: s.positionY)
                let needed = Orientation.to8(Int8(bitPattern: Pos32.direction(from: from, to: lookAt)))
                let current = s.rotationSpriteDiff & 0x7

                if needed == current { return 0 }

                // Signed 0..7 difference; pick the shorter direction.
                var rotateDiff = Int(needed) - Int(current)
                if rotateDiff < 0 { rotateDiff += 8 }
                var newRot = Int(current)
                if rotateDiff < 4 {
                    newRot += 1
                } else {
                    newRot -= 1
                }
                newRot &= 0x7

                var updated = s
                updated.rotationSpriteDiff = UInt8(newRot)
                host.structures[poolIndex] = updated
                return 1
            }
        }

        /// `Script_Structure_GetDirection` (structure slot 0x0A) — port
        /// of `src/script/structure.c:440`. Returns `(rotationSpriteDiff
        /// << 5)` for invalid encoded input, else
        /// `Orientation.to8(direction(structure, target)) << 5`. The `<< 5`
        /// is not a bug — it's the OpenDUNE convention that the EMC uses
        /// as a sprite-frame stride.
        public static func makeGetDirectionStructure(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.peek(engine: &engine, position: 1)
                guard let (_, s) = currentStructure(host: host) else { return 0 }
                let eidx = Scripting.EncodedIndex(raw: encoded)
                if !isValid(encoded: eidx, host: host) {
                    return UInt16(s.rotationSpriteDiff) &<< 5
                }
                guard let lookAt = Pos32.of(eidx, host: host) else {
                    return UInt16(s.rotationSpriteDiff) &<< 5
                }
                let from = Pos32(x: s.positionX, y: s.positionY)
                let o8 = Orientation.to8(Int8(bitPattern: Pos32.direction(from: from, to: lookAt)))
                return UInt16(o8) &<< 5
            }
        }

        /// `Script_Structure_Fire` (structure slot 0x0B) — port of
        /// `src/script/structure.c:513`. Reads `engine.variables[2]` as
        /// the encoded target, picks `UNIT_BULLET` (normal turret) or
        /// `UNIT_MISSILE_TURRET` (rocket turret at ≥ 3 tiles range),
        /// spawns the bullet at the structure's centre via
        /// `Simulation.Units.createBullet`, stamps `originEncoded`, and
        /// returns the requested fireDelay (passed back to the EMC
        /// engine).
        public static func makeFireStructure(host: Host) -> VM.Function {
            return { engine in
                let target = engine.variables[2]
                if target == 0 { return 0 }
                guard let (_, s) = currentStructure(host: host) else { return 0 }
                let tEnc = Scripting.EncodedIndex(raw: target)
                guard let tPos = Pos32.of(tEnc, host: host) else { return 0 }

                // ROCKET_TURRET (type 16) with long-range target uses a
                // MISSILE_TURRET; everything else uses a plain BULLET.
                let sPos = Pos32(x: s.positionX, y: s.positionY)
                let distance = UInt32(Pos32.distance(sPos, tPos))

                let bulletType: UInt8
                let damage: UInt16
                let fireDelay: UInt16
                if s.type == 16 && distance >= 0x300 {
                    bulletType = 20  // MISSILE_TURRET
                    damage = 30
                    fireDelay = Simulation.UnitInfo.lookup(7 /*LAUNCHER*/)?.fireDelay ?? 120
                } else {
                    bulletType = 23  // BULLET
                    damage = 20
                    fireDelay = Simulation.UnitInfo.lookup(9 /*TANK*/)?.fireDelay ?? 80
                }

                let center = Pos32(
                    x: s.positionX &+ 0x80,
                    y: s.positionY &+ 0x80
                )
                guard let bulletIdx = Simulation.Units.createBullet(
                    position: center, type: bulletType,
                    houseID: s.houseID, damage: damage,
                    target: target, host: host
                ) else { return 0 }
                var bullet = host.units[bulletIdx]
                bullet.originEncoded = Scripting.EncodedIndex.structure(s.index).raw
                host.units[bulletIdx] = bullet
                return fireDelay
            }
        }

        // MARK: Batch 9 — Team AI (read-only slots)

        /// `Script_Team_AddClosestUnit` (team slot 0x03) — port of
        /// `src/script/team.c:70`. Walks the team's house unit pool
        /// and picks the closest byScenario + matching-movementType
        /// unit that is either unaligned (`team == 0`) or assigned to
        /// a weaker team that still has slack above `minMembers`.
        /// SABOTEUR units are skipped. Moves the chosen unit into the
        /// current team (via `Unit_RemoveFromTeam` then
        /// `Unit_AddToTeam`) and returns the new remaining capacity.
        public static func makeAddClosestUnitTeam(host: Host) -> VM.Function {
            return { _ in
                guard let (teamIdx, t) = currentTeam(host: host) else { return 0 }
                if t.members >= t.maxMembers { return 0 }

                let tPos = Pos32(x: t.positionX, y: t.positionY)
                var closest: Int?
                var minDistance: UInt16 = 0
                var closestFromTeam: Int?
                var minDistanceFromTeam: UInt16 = 0

                var query = Simulation.PoolQuery(houseID: t.houseID)
                while let u = host.units.next(&query) {
                    if !u.byScenario { continue }
                    if u.type == 6 /*SABOTEUR*/ { continue }
                    guard let info = Simulation.UnitInfo.lookup(u.type) else { continue }
                    if UInt16(info.movementType.rawValue) != t.movementType { continue }

                    let d = Pos32.distance(tPos, Pos32(x: u.positionX, y: u.positionY))

                    if u.team == 0 {
                        // Unaligned — first preference.
                        if d >= minDistance && minDistance != 0 { continue }
                        minDistance = d
                        closest = Int(u.index)
                        continue
                    }

                    // Already on a team — only steal from teams with slack.
                    let otherIdx = Int(u.team) - 1
                    guard otherIdx >= 0, otherIdx < host.teams.slots.count else { continue }
                    let other = host.teams.slots[otherIdx]
                    if !other.isUsed || other.members <= other.minMembers { continue }

                    if d >= minDistanceFromTeam && minDistanceFromTeam != 0 { continue }
                    minDistanceFromTeam = d
                    closestFromTeam = Int(u.index)
                }

                let chosen = closest ?? closestFromTeam
                guard let unitIndex = chosen else { return 0 }

                _ = Simulation.Units.removeFromTeam(unitIndex: unitIndex, host: host)
                return Simulation.Units.addToTeam(
                    unitIndex: unitIndex, teamIndex: teamIdx, host: host
                )
            }
        }

        /// `Script_Team_GetMembers` (team slot 0x02) — port of
        /// `src/script/team.c:28`. Returns the current team's
        /// `members` count or 0 when no team is selected.
        public static func makeGetMembersTeam(host: Host) -> VM.Function {
            return { _ in
                guard let (_, t) = currentTeam(host: host) else { return 0 }
                return t.members
            }
        }

        /// `Script_Team_GetVariable6` (team slot 0x0C) — `t->minMembers`.
        /// Name matches OpenDUNE's misnomer (`variable_06` is actually
        /// the minimum member threshold in memory).
        public static func makeGetVariable6Team(host: Host) -> VM.Function {
            return { _ in
                guard let (_, t) = currentTeam(host: host) else { return 0 }
                return t.minMembers
            }
        }

        /// `Script_Team_GetTarget` (team slot 0x0D) — returns `t->target`
        /// (encoded index). 0 when no target.
        public static func makeGetTargetTeam(host: Host) -> VM.Function {
            return { _ in
                guard let (_, t) = currentTeam(host: host) else { return 0 }
                return t.target
            }
        }

        /// `Script_Team_DisplayText` (team slot 0x01) — port of
        /// `src/script/team.c:415`. Skips drawing when the team belongs
        /// to the player (hostile messages only). Peeks string index +
        /// 3 args from the stack.
        public static func makeDisplayTextTeam(host: Host) -> VM.Function {
            return { engine in
                guard let (_, t) = currentTeam(host: host) else { return 0 }
                if let player = host.playerHouseID, t.houseID == player { return 0 }
                let textIndex = Int(Scripting.peek(engine: &engine, position: 1))
                let arg1 = Scripting.peek(engine: &engine, position: 2)
                let arg2 = Scripting.peek(engine: &engine, position: 3)
                let arg3 = Scripting.peek(engine: &engine, position: 4)
                guard textIndex >= 0, textIndex < host.texts.count else { return 0 }
                host.textLog.append(Host.DisplayedText(
                    text: host.texts[textIndex],
                    arg1: arg1, arg2: arg2, arg3: arg3
                ))
                return 0
            }
        }

        /// `Script_Team_FindBestTarget` (team slot 0x06) — port of
        /// `src/script/team.c:256`. Walks `host.units` for members of
        /// the current team, calls `TargetAcquisition.findBestTargetEncoded`
        /// with `mode = 4` for KAMIKAZE teams (prefer structures) or
        /// `mode = 0` otherwise. First match wins (as soon as a member
        /// returns a valid target, the team locks on).
        public static func makeFindBestTargetTeam(host: Host) -> VM.Function {
            return { _ in
                guard let (teamIdx, t) = currentTeam(host: host) else { return 0 }
                let mode: UInt16 = t.action == UInt16(Simulation.TeamAction.kamikaze.rawValue) ? 4 : 0

                var query = Simulation.PoolQuery(houseID: t.houseID)
                while let u = host.units.next(&query) {
                    // Only members of this team count.
                    if Int(u.team) - 1 != Int(t.index) { continue }
                    let target = Simulation.TargetAcquisition.findBestTargetEncoded(
                        attackerIndex: Int(u.index), mode: mode, host: host
                    )
                    if target == 0 { continue }
                    if t.target == target { return target }
                    var updated = t
                    updated.target = target
                    // `targetTile` is only used as a bool gate in
                    // OpenDUNE; we mirror that rather than porting
                    // `Tile_GetTileInDirectionOf` for now.
                    updated.targetTile = 1
                    host.teams[teamIdx] = updated
                    return target
                }
                return 0
            }
        }

        /// `Script_Team_Load` (team slot 0x08) — port of
        /// `src/script/team.c:296`. Switches the team's `action` to
        /// `peek(1)`. OpenDUNE also resets the team's script engine
        /// and loads a new entry point; we stub that out until the
        /// team tick loop lands. Returns 0.
        public static func makeLoadTeam(host: Host) -> VM.Function {
            return { engine in
                let type = Scripting.peek(engine: &engine, position: 1)
                guard let (teamIdx, t) = currentTeam(host: host) else { return 0 }
                if t.action == type { return 0 }
                var updated = t
                updated.action = type
                host.teams[teamIdx] = updated
                return 0
            }
        }

        /// `Script_Team_Load2` (team slot 0x09) — same as `Load` but
        /// reads the team's `actionStart` instead of a stack arg.
        public static func makeLoad2Team(host: Host) -> VM.Function {
            return { _ in
                guard let (teamIdx, t) = currentTeam(host: host) else { return 0 }
                let type = t.actionStart
                if t.action == type { return 0 }
                var updated = t
                updated.action = type
                host.teams[teamIdx] = updated
                return 0
            }
        }

        // MARK: Batch 7 — simple structure mutators

        /// `Script_Structure_Destroy` — frees the structure slot. The
        /// full OpenDUNE behaviour (explosion, debris tiles, damage
        /// propagation) is deferred.
        public static func makeDestroyStructure(host: Host) -> VM.Function {
            return { _ in
                guard let (poolIndex, _) = currentStructure(host: host) else { return 0 }
                host.structures.free(at: poolIndex)
                return 0
            }
        }

        // MARK: Batch 4 — structure-specific generics

        /// `Script_Structure_GetState` (structure slot 0x0D) — returns
        /// `s->state` reinterpret-cast to `UInt16`. Zero on no current
        /// structure.
        public static func makeGetStateStructure(host: Host) -> VM.Function {
            return { _ in
                guard let (_, slot) = currentStructure(host: host) else { return 0 }
                return UInt16(bitPattern: slot.state)
            }
        }

        /// `Script_Structure_SetState` (structure slot 0x04) — writes
        /// `peek(1)` to `s->state`. The `-2` DETECT sentinel resolves to
        /// IDLE/READY/BUSY based on `linkedID` and `countDown`. Returns 0.
        /// The `Structure_UpdateMap` side-effect is deferred.
        public static func makeSetStateStructure(host: Host) -> VM.Function {
            return { engine in
                guard let (poolIndex, slot) = currentStructure(host: host) else { return 0 }
                var resolved = Int16(bitPattern: Scripting.peek(engine: &engine, position: 1))
                if resolved == -2 {
                    if slot.linkedID == 0xFF {
                        resolved = 0           // IDLE
                    } else if slot.countDown == 0 {
                        resolved = 2           // READY
                    } else {
                        resolved = 1           // BUSY
                    }
                }
                var updated = slot
                updated.state = resolved
                host.structures[poolIndex] = updated
                return 0
            }
        }

        // MARK: Batch 5 — further generics (no new state)

        /// `Script_General_DelayRandom` — `(Tools_Random_256() * peek(1)) / 256 / 5`.
        /// Writes `engine.delay` and returns the same value. Shares the
        /// `RandomSource.tools` stream with any other consumer.
        public static func makeDelayRandom(source: RandomSource, host: Host) -> VM.Function {
            return { engine in
                let peek = Scripting.peek(engine: &engine, position: 1)
                let ctxObj: String
                switch host.currentObject {
                case .unit(let idx): ctxObj = "u\(idx)"
                case .structure(let idx): ctxObj = "s\(idx)"
                case .team(let idx): ctxObj = "t\(idx)"
                case .none: ctxObj = "?"
                }
                source.currentTraceContext = "DelayRandom \(ctxObj)"
                let r = UInt16(source.toolsNext())
                source.currentTraceContext = ""
                let d = (r &* peek) / 256 / 5
                engine.delay = d
                return d
            }
        }

        /// `Script_General_GetIndexType` — returns the OpenDUNE `IT_*`
        /// constant (`0` none, `1` tile, `2` unit, `3` structure). Invalid
        /// encoded index → `0xFFFF`.
        public static func makeGetIndexType(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                guard isValid(encoded: encoded, host: host) else { return 0xFFFF }
                switch encoded.kind {
                case .none:      return 0
                case .tile:      return 1
                case .unit:      return 2
                case .structure: return 3
                }
            }
        }

        /// `Script_General_DecodeIndex` — returns `EncodedIndex.decoded`
        /// (pool index for unit/structure; `Tile_PackXY` for tile).
        /// Invalid → `0xFFFF`.
        public static func makeDecodeIndex(host: Host) -> VM.Function {
            return { engine in
                let encoded = Scripting.EncodedIndex(raw: Scripting.peek(engine: &engine, position: 1))
                guard isValid(encoded: encoded, host: host) else { return 0xFFFF }
                return encoded.decoded
            }
        }

        /// `Script_General_GetLinkedUnitType` — reads the current object's
        /// `linkedID` (unit or structure). Returns the linked unit's
        /// `type`, or `0xFFFF` when unlinked / the linked slot is freed.
        public static func makeGetLinkedUnitType(host: Host) -> VM.Function {
            return { _ in
                let linkedID: UInt8
                switch host.currentObject {
                case .unit(let idx)?:
                    guard idx >= 0, idx < host.units.slots.count,
                          host.units.slots[idx].isUsed else { return 0xFFFF }
                    linkedID = host.units.slots[idx].linkedID
                case .structure(let idx)?:
                    guard idx >= 0, idx < host.structures.slots.count,
                          host.structures.slots[idx].isUsed else { return 0xFFFF }
                    linkedID = host.structures.slots[idx].linkedID
                case .team?, .none:
                    return 0xFFFF
                }
                if linkedID == 0xFF { return 0xFFFF }
                let linkedIndex = Int(linkedID)
                guard linkedIndex < host.units.slots.count else { return 0xFFFF }
                let linked = host.units.slots[linkedIndex]
                guard linked.isUsed, linked.isAllocated else { return 0xFFFF }
                return UInt16(linked.type)
            }
        }

        /// `Script_General_FindIdle` — two-mode:
        /// - encoded structure index: `1` when same-house + IDLE, else `0`;
        /// - IT_UNIT / IT_TILE: always `0`;
        /// - otherwise: treat `peek(1)` as a structure type, walk the
        ///   structure pool filtered by current house + that type, and
        ///   return the encoded index of the first IDLE match (else `0`).
        public static func makeFindIdle(host: Host) -> VM.Function {
            return { engine in
                let raw = Scripting.peek(engine: &engine, position: 1)
                let encoded = Scripting.EncodedIndex(raw: raw)
                guard let currentHouse = host.currentHouseID else { return 0 }
                switch encoded.kind {
                case .unit, .tile:
                    return 0
                case .structure:
                    let idx = Int(encoded.decoded)
                    guard idx < host.structures.slots.count else { return 0 }
                    let slot = host.structures.slots[idx]
                    guard slot.isUsed, slot.houseID == currentHouse, slot.state == 0 else { return 0 }
                    return 1
                case .none:
                    let type = UInt8(truncatingIfNeeded: raw)
                    var query = Simulation.PoolQuery(houseID: currentHouse, type: type)
                    while let slot = host.structures.next(&query) {
                        if slot.state == 0 {
                            return Scripting.EncodedIndex.structure(slot.index).raw
                        }
                    }
                    return 0
                }
            }
        }

        /// `Script_Unit_Harvest` (unit slot 0x2A) — port of
        /// `src/script/unit.c:1640..1670`. Advances a harvester's
        /// `amount` on a spice tile and probabilistically decrements
        /// the tile's spice level.
        ///
        /// Contract:
        /// - Returns 0 if the unit isn't a HARVESTER, if its `amount`
        ///   is already ≥ 100, or if it isn't currently on a spice
        ///   tile (per `host.spiceMap`).
        /// - Otherwise consumes **exactly 2 `tools.next()` bytes** —
        ///   the first is `amount += (rand & 1)`, the second decides
        ///   "keep harvesting" (return 1) vs "drain tile + end"
        ///   (return 0). Both draws happen unconditionally once the
        ///   guards pass, so RNG stays in lockstep with OpenDUNE.
        /// - Flips `inTransport = true` on first pickup (same flag
        ///   OpenDUNE uses as the "has cargo" signal).
        /// - Returns 1 with probability 31/32 (the `& 0x1F != 0`
        ///   branch), else 0 after calling `spiceMap.apply(delta:-1,at:)`.
        ///
        /// Needs `host.spiceMap` wired (parity harness loads it from
        /// the save's tile grid; gameplay runtime sets it in
        /// `ScenarioRuntime`). Without it the function returns 0 and
        /// takes no side effects — matching the old `noOperation`
        /// behaviour so gameplay code that hasn't wired spiceMap yet
        /// doesn't regress.
        public static func makeHarvestUnit(host: Host, source: RandomSource) -> VM.Function {
            return { _ in
                guard let (poolIndex, slot) = currentUnit(host: host) else { return 0 }
                if slot.type != 16 /* UNIT_HARVESTER */ { return 0 }
                if slot.amount >= 100 { return 0 }
                guard var spiceMap = host.spiceMap else { return 0 }
                let tileX = Int(slot.positionX) / 256
                let tileY = Int(slot.positionY) / 256
                guard (0..<64).contains(tileX), (0..<64).contains(tileY) else { return 0 }
                let packed = UInt16(tileY * 64 + tileX)
                let level = spiceMap[packed]
                guard level == .thin || level == .thick else { return 0 }

                var updated = slot
                // Consume RNG byte #1 — low bit is the amount bump.
                source.currentTraceContext = "Harvest.bump u\(poolIndex)"
                let bump = source.toolsNext() & 1
                updated.amount = updated.amount &+ bump
                updated.inTransport = true
                if updated.amount > 100 { updated.amount = 100 }
                host.units[poolIndex] = updated
                // Consume RNG byte #2 — 31/32 chance of "keep going".
                source.currentTraceContext = "Harvest.drainRoll u\(poolIndex)"
                let roll = source.toolsNext()
                source.currentTraceContext = ""
                if (roll & 0x1F) != 0 {
                    return 1
                }
                // Drain one spice level on this tile. `spiceMap` is a
                // value type so we must write through `host.spiceMap`.
                _ = spiceMap.apply(delta: -1, at: packed)
                host.spiceMap = spiceMap
                host.spiceLevelDidChange?(packed, spiceMap[packed], spiceMap)
                return 0
            }
        }

        // MARK: Helpers

        private static func currentUnit(host: Host) -> (Int, Simulation.UnitSlot)? {
            guard case .unit(let poolIndex)? = host.currentObject,
                  poolIndex >= 0, poolIndex < host.units.slots.count else { return nil }
            let slot = host.units.slots[poolIndex]
            guard slot.isUsed, slot.isAllocated else { return nil }
            return (poolIndex, slot)
        }

        private static func currentStructure(host: Host) -> (Int, Simulation.StructureSlot)? {
            guard case .structure(let poolIndex)? = host.currentObject,
                  poolIndex >= 0, poolIndex < host.structures.slots.count else { return nil }
            let slot = host.structures.slots[poolIndex]
            guard slot.isUsed else { return nil }
            return (poolIndex, slot)
        }

        private static func currentTeam(host: Host) -> (Int, Simulation.TeamSlot)? {
            guard case .team(let poolIndex)? = host.currentObject,
                  poolIndex >= 0, poolIndex < host.teams.slots.count else { return nil }
            let slot = host.teams.slots[poolIndex]
            guard slot.isUsed else { return nil }
            return (poolIndex, slot)
        }

        /// Tile32 position of the current object (unit or structure), or
        /// nil when no currentObject is set.
        private static func currentPosition(host: Host) -> Pos32? {
            switch host.currentObject {
            case .unit(let idx)?:
                guard idx >= 0, idx < host.units.slots.count else { return nil }
                let s = host.units.slots[idx]
                guard s.isUsed, s.isAllocated else { return nil }
                return Pos32(x: s.positionX, y: s.positionY)
            case .structure(let idx)?:
                guard idx >= 0, idx < host.structures.slots.count else { return nil }
                let s = host.structures.slots[idx]
                guard s.isUsed else { return nil }
                return Pos32(x: s.positionX, y: s.positionY)
            case .team(let idx)?:
                guard idx >= 0, idx < host.teams.slots.count else { return nil }
                let t = host.teams.slots[idx]
                guard t.isUsed else { return nil }
                return Pos32(x: t.positionX, y: t.positionY)
            case .none:
                return nil
            }
        }

        /// Live `Tools_Index_IsValid`: pool slot exists, `isUsed`, and for
        /// units also `isAllocated`. `.tile` is always valid; `.none` never.
        private static func isValid(encoded: Scripting.EncodedIndex, host: Host) -> Bool {
            switch encoded.kind {
            case .none: return false
            case .tile: return true
            case .unit:
                let idx = Int(encoded.decoded)
                guard idx < host.units.slots.count else { return false }
                let s = host.units.slots[idx]
                return s.isUsed && s.isAllocated
            case .structure:
                let idx = Int(encoded.decoded)
                guard idx < host.structures.slots.count else { return false }
                return host.structures.slots[idx].isUsed
            }
        }
    }
}
