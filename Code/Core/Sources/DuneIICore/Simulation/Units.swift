import Foundation

extension Simulation {
    /// Unit-creation helpers. Mirrors OpenDUNE's `Unit_Create` /
    /// `Unit_CreateBullet` (`src/unit.c`). Namespaced under `Simulation`
    /// so both `Scripting.Functions` and test harnesses can invoke them
    /// without reaching into `UnitPool` internals.
    public enum Units {

        /// Resolves a freshly-allocated unit's `actionID` the same way
        /// `Unit_Create` does at `src/unit.c:462`:
        ///
        ///     Unit_SetAction(u, (houseID == g_playerHouseID)
        ///                         ? ui->o.actionsPlayer[3]
        ///                         : ui->actionAI);
        ///
        /// `Unit_SetAction` short-circuits on `ACTION_INVALID`
        /// (`src/unit.c:502`), so when the chosen action is invalid we
        /// fall back to the default `ACTION_GUARD` written earlier in
        /// `Unit_Create` (`src/unit.c:425`). Returns the final
        /// `actionID` byte to write into the slot.
        static func resolvedInitialAction(
            info: UnitInfo, houseID: UInt8, host: Scripting.Host
        ) -> UInt8 {
            let playerHouseID = host.playerHouseID ?? Simulation.House.invalidID
            let action = (houseID == playerHouseID)
                ? (info.actionsPlayer.count >= 4 ? info.actionsPlayer[3] : info.actionAI)
                : info.actionAI
            if action == ActionID.invalid {
                return ActionID.guard_
            }
            return action
        }

        /// Narrow port of `Unit_Create` covering the factory-completion
        /// spawn path (slice 5b-build): allocate a unit of `type` owned
        /// by `houseID` at `(tileX, tileY)`. Returns the pool slot
        /// index, or `nil` when inputs are out of range or the pool is
        /// full.
        ///
        /// Position is centred in the target tile (pos32 `tile * 256 + 128`).
        /// `seenByHouses = 0xFF` matches the scenario-spawn shortcut —
        /// new factory-spawned units are immediately visible to every
        /// house (no fog reveal yet).
        /// Wingers get `speed = 255` (cruise-in behaviour identical to
        /// `Unit_CreateBullet`'s pattern); ground units leave `speed`
        /// at the pool default.
        ///
        /// Deferred vs OpenDUNE `Unit_Create`:
        /// - `Script_Load` — scheduler picks up new slots on next tick.
        /// - Fog-of-war / `Tile_RemoveFogInRadius`.
        /// - MCV-specific deploy logic.
        /// - Per-house `linkedID` / transport initialisation beyond pool
        ///   defaults.
        /// - Orientation — defaults to north-facing (`0`).
        @discardableResult
        public static func createUnit(
            type: UInt8,
            houseID: UInt8,
            tileX: Int,
            tileY: Int,
            pool: inout UnitPool
        ) -> Int? {
            guard houseID < 6 else { return nil }
            guard type < 27 else { return nil }
            guard let info = UnitInfo.lookup(type) else { return nil }
            guard let idx = pool.allocateForType(type: type, houseID: houseID) else {
                return nil
            }
            var slot = pool[idx]
            slot.hitpoints = info.hitpoints
            slot.positionX = UInt16(clamping: tileX * 256 + 128)
            slot.positionY = UInt16(clamping: tileY * 256 + 128)
            slot.seenByHouses = 0xFF
            pool[idx] = slot
            if info.movementType == .winger {
                // Wingers cruise in at full throttle from spawn. The
                // setSpeed pipeline computes speed/speedPerTick from
                // the per-type movingSpeedFactor — matches OpenDUNE's
                // `Unit_Create` path for air units.
                setSpeed(poolIndex: idx, speedPercent: 255, units: &pool)
            }
            Log.info(
                "createUnit slot=\(idx) type=\(type) house=\(houseID) tile=(\(tileX),\(tileY)) hp=\(slot.hitpoints) speed=\(pool[idx].speed) speedPerTick=\(pool[idx].speedPerTick)",
                tracer: .label("unit-create")
            )
            return idx
        }

        /// Carryall pickup slice 8b. Partial port of OpenDUNE's
        /// `Unit_CallUnitByType` tail (`src/unit.c:2131`) shortcut: spawn
        /// a CARRYALL (type 0) owned by the harvester's house at the
        /// harvester's current pixel position, link the harvester via
        /// `linkedID`, set `inTransport=true` on both sides, and route
        /// the carryall at `destinationRefineryIndex`'s encoded index.
        ///
        /// Returns the new carryall pool slot, or `nil` when inputs are
        /// invalid / pools are full. Logs the spawn under the
        /// `carryall` tracer.
        ///
        /// Deferred (slice 8c): fly-to-pickup phase, drop-off at the
        /// destination refinery, carryall return-to-origin. In this
        /// slice the carryall teleports to the harvester's tile and
        /// begins its ferry flight — visually "pops in" above the busy
        /// refinery.
        @discardableResult
        public static func callCarryall(
            harvesterIndex: Int,
            destinationRefineryIndex: Int,
            units: inout UnitPool,
            structures: StructurePool
        ) -> Int? {
            guard harvesterIndex >= 0, harvesterIndex < UnitPool.capacity else { return nil }
            let harvester = units[harvesterIndex]
            guard harvester.isUsed, harvester.isAllocated else { return nil }
            guard harvester.type == 16 /* HARVESTER */ else { return nil }
            guard destinationRefineryIndex >= 0,
                  destinationRefineryIndex < structures.slots.count
            else { return nil }
            let refinery = structures.slots[destinationRefineryIndex]
            guard refinery.isUsed, refinery.isAllocated else { return nil }
            guard refinery.type == 12 /* REFINERY */ else { return nil }
            guard refinery.houseID == harvester.houseID else { return nil }

            guard let carryallIdx = units.allocateForType(
                type: 0 /* CARRYALL */, houseID: harvester.houseID
            ) else {
                Log.warning(
                    "carryall-spawn FAILED — pool full (house=\(harvester.houseID) harvester=\(harvesterIndex))",
                    tracer: .label("carryall")
                )
                return nil
            }
            var carryall = units[carryallIdx]
            carryall.positionX = harvester.positionX
            carryall.positionY = harvester.positionY
            carryall.hitpoints = UnitInfo.lookup(0)?.hitpoints ?? 100
            carryall.seenByHouses = 0xFF
            carryall.inTransport = true
            carryall.linkedID = UInt8(truncatingIfNeeded: harvesterIndex)
            carryall.targetMove = Scripting.EncodedIndex.structure(
                UInt16(truncatingIfNeeded: destinationRefineryIndex)
            ).raw
            units[carryallIdx] = carryall
            // Wingers cruise in at full speed — matches `createUnit`
            // handling of winger-type spawns.
            setSpeed(poolIndex: carryallIdx, speedPercent: 255, units: &units)

            // Mark the harvester as in-transport so tickHarvesting
            // doesn't re-route it while the carryall ferries.
            var h = units[harvesterIndex]
            h.inTransport = true
            units[harvesterIndex] = h

            let rx = Int(refinery.positionX) / 256
            let ry = Int(refinery.positionY) / 256
            Log.info(
                "carryall-spawn slot=\(carryallIdx) house=\(harvester.houseID) harvester=\(harvesterIndex) refinery=\(destinationRefineryIndex) tile=(\(rx),\(ry))",
                tracer: .label("carryall")
            )
            return carryallIdx
        }

        /// Carryall pickup slice 8c. Drop-off counterpart to
        /// `callCarryall`. Detaches the harvester from the carryall,
        /// clears `inTransport` on both sides, snaps the harvester
        /// position to the carryall's current tile (by arrival the
        /// carryall has been flown to the destination refinery by
        /// `tickMovement`), and frees the carryall slot.
        ///
        /// Returns the dropped-off harvester pool index on success,
        /// `nil` when the carryall isn't ferrying anything (not
        /// in-transport / no linkedID / not a CARRYALL). Logs under
        /// the `carryall` tracer.
        ///
        /// Deferred vs. OpenDUNE: no "fly off to map edge" return
        /// trip — we free the carryall the moment the drop lands.
        /// Future slices can route the empty carryall back for reuse.
        @discardableResult
        public static func dropCarryall(
            carryallIndex: Int,
            units: inout UnitPool,
            structures: StructurePool
        ) -> Int? {
            guard carryallIndex >= 0, carryallIndex < UnitPool.capacity else { return nil }
            let carryall = units[carryallIndex]
            guard carryall.isUsed, carryall.isAllocated else { return nil }
            guard carryall.type == 0 /* CARRYALL */ else { return nil }
            guard carryall.inTransport else { return nil }
            guard carryall.linkedID != 0xFF else { return nil }
            let harvesterIdx = Int(carryall.linkedID)
            guard harvesterIdx >= 0, harvesterIdx < UnitPool.capacity else { return nil }
            var harvester = units[harvesterIdx]
            guard harvester.isUsed, harvester.type == 16 /* HARVESTER */ else { return nil }

            // Place the harvester at the carryall's current tile —
            // tickMovement has already snapped the carryall to the
            // destination refinery's anchor. The harvester's RETURN
            // action then docks on the next tickHarvesting pass via
            // the existing refineryAt flow.
            harvester.positionX = carryall.positionX
            harvester.positionY = carryall.positionY
            harvester.inTransport = false
            units[harvesterIdx] = harvester

            units.free(at: carryallIndex)

            Log.info(
                "carryall-drop slot=\(carryallIndex) harvester=\(harvesterIdx) at=(\(harvester.positionX),\(harvester.positionY))",
                tracer: .label("carryall")
            )
            return harvesterIdx
        }

        /// Port of `Unit_CreateBullet` (`src/unit.c:1954`). Allocates a
        /// projectile-type unit in the pool's bullet range (12..15),
        /// sets its position / orientation / target / hitpoints.
        /// Returns the new bullet's pool index, or `nil` when the pool
        /// is full, the target is invalid, or the type isn't a known
        /// bullet/missile.
        ///
        /// What this slice does NOT do (all deferred):
        /// - `notAccurate` random drift on missile destination.
        /// - `bulletSound` voice-play + `Tile_RemoveFogInRadius`.
        /// - `bulletIsBig` flag on large bullets (needs slot field).
        /// - Script reset for the new bullet (EMC BULLET script runs
        ///   in a later slice).
        @discardableResult
        public static func createBullet(
            position: Pos32,
            type: UInt8,
            houseID: UInt8,
            damage: UInt16,
            target: UInt16,
            host: Scripting.Host
        ) -> Int? {
            // Target must be valid.
            let encoded = Scripting.EncodedIndex(raw: target)
            guard isValid(encoded: encoded, host: host) else {
                Log.debug(
                    "createBullet type=\(type) FAIL target-invalid raw=\(String(format: "0x%04X", target))",
                    tracer: .label("fire")
                )
                return nil
            }
            guard let info = UnitInfo.lookup(type) else {
                Log.debug(
                    "createBullet type=\(type) FAIL no-info",
                    tracer: .label("fire")
                )
                return nil
            }
            // Match OpenDUNE's `Unit_CreateBullet` (`src/unit.c:1962`):
            // `tile = Tools_Index_GetTile(target)`. For structures
            // that's the layout-adjusted centre, not the raw stored
            // top-left position — so a bullet fired at a 2x2 CYARD
            // heads NE toward the centre rather than N toward the
            // anchor corner.
            guard let targetPos = Pos32.targetTile(encoded, host: host) else {
                Log.debug(
                    "createBullet type=\(type) FAIL target-pos",
                    tracer: .label("fire")
                )
                return nil
            }

            switch type {
            case 18, 19, 20, 21, 22:
                // Missile family: spawn at shooter's position, facing target.
                let orientation = Pos32.direction(from: position, to: targetPos)
                guard let bulletIdx = host.units.allocateForType(type: type, houseID: houseID) else {
                    return nil
                }
                var bullet = host.units[bulletIdx]
                bullet.positionX = position.x
                bullet.positionY = position.y
                // OpenDUNE's `Unit_Create` calls `Unit_SetOrientation`
                // with `rotateInstantly=true` for both levels (`src/unit.c:405..406`),
                // which snaps all three fields (current/target/speed=0)
                // immediately.
                bullet.orientationCurrent = Int8(bitPattern: orientation)
                bullet.orientationTarget = Int8(bitPattern: orientation)
                bullet.orientationSpeed = 0
                // Port of `Unit_Create` (`src/unit.c:425` + `src/unit.c:462`):
                // the initial `actionID = ACTION_GUARD` write is followed
                // by `Unit_SetAction(u, player ? actionsPlayer[3] : actionAI)`.
                // For bullets / missiles, `actionAI = ACTION_INVALID`, which
                // makes `Unit_SetAction` early-return at `src/unit.c:502`
                // and leaves `actionID = ACTION_GUARD`. The player arm
                // picks `actionsPlayer[3]` (= STOP) which DOES write.
                bullet.actionID = resolvedInitialAction(info: info, houseID: houseID, host: host)
                bullet.targetAttack = target
                bullet.hitpoints = damage
                bullet.currentDestinationX = targetPos.x
                bullet.currentDestinationY = targetPos.y
                bullet.route = [UInt8](repeating: 0, count: 14)
                bullet.route[0] = 0xFF
                bullet.fireDelay = UInt8(truncatingIfNeeded: info.fireDistance & 0xFF)
                // Winger targets get doubled travel budget (AA-style
                // lead-the-target behaviour, from OpenDUNE).
                if encoded.kind == .unit,
                   let targetSlot = host.unitSlot(for: encoded),
                   let targetInfo = UnitInfo.lookup(targetSlot.type),
                   targetInfo.movementType == .winger {
                    bullet.fireDelay = UInt8(clamping: UInt16(bullet.fireDelay) &* 2)
                }
                host.units[bulletIdx] = bullet
                // Route through setSpeed so speedPerTick is set for
                // the subpixel mover. All bullets/missiles are
                // MOVEMENT_WINGER.
                setSpeed(poolIndex: bulletIdx, speedPercent: 255, units: &host.units)
                return bulletIdx

            case 23, 24:
                // Bullet / sonic blast: step off the shooter's tile so
                // the bullet doesn't land on itself.
                let orientation = Pos32.direction(from: position, to: targetPos)
                let stepped1 = Pos32.moved(position, orientation: 0, distance: 32)
                let spawn = Pos32.moved(stepped1, orientation: orientation, distance: 128)
                guard let bulletIdx = host.units.allocateForType(type: type, houseID: houseID) else {
                    Log.debug(
                        "createBullet type=\(type) house=\(houseID) FAIL allocateForType (pool full)",
                        tracer: .label("fire")
                    )
                    return nil
                }
                var bullet = host.units[bulletIdx]
                bullet.positionX = spawn.x
                bullet.positionY = spawn.y
                // OpenDUNE's `Unit_Create` calls `Unit_SetOrientation`
                // with `rotateInstantly=true` for both levels
                // (`src/unit.c:405..406`).
                bullet.orientationCurrent = Int8(bitPattern: orientation)
                bullet.orientationTarget = Int8(bitPattern: orientation)
                bullet.orientationSpeed = 0
                // Same `Unit_Create` semantics as the missile arm above:
                // BULLET + SONIC_BLAST both carry `actionAI = INVALID`,
                // so an AI-spawned bullet keeps the default `GUARD`; a
                // player-spawned bullet gets `actionsPlayer[3] = STOP`.
                bullet.actionID = resolvedInitialAction(info: info, houseID: houseID, host: host)
                // OpenDUNE's UNIT_BULLET / UNIT_SONIC_BLAST arm at
                // `src/unit.c:2003..2029` does NOT set `targetAttack`;
                // only the missile arm (cases 18..22) does. The bullet
                // uses `currentDestination` for arrival detection.
                bullet.hitpoints = damage
                bullet.currentDestinationX = targetPos.x
                bullet.currentDestinationY = targetPos.y
                // OpenDUNE's Unit_Create memsets the slot to zero and
                // then sets route[0]=0xFF; route[1..13] stay zero.
                // Swift's slot default has every route entry = 0xFF,
                // so match by explicit reset here.
                bullet.route = [UInt8](repeating: 0, count: 14)
                bullet.route[0] = 0xFF
                if type == 24 {
                    bullet.fireDelay = UInt8(truncatingIfNeeded: info.fireDistance & 0xFF)
                }
                host.units[bulletIdx] = bullet
                setSpeed(poolIndex: bulletIdx, speedPercent: 255, units: &host.units)
                return bulletIdx

            default:
                return nil
            }
        }

        // MARK: Orientation (Unit_SetOrientation port)

        /// Port of OpenDUNE's `Unit_SetOrientation` (`src/unit.c:1671`).
        /// Writes `orientationTarget` + seeds `orientationSpeed` for
        /// gradual rotation (or snaps `orientationCurrent` when
        /// `rotateInstantly` is true). `level=0` for body, `level=1`
        /// for turret (turret track not yet tracked on UnitSlot).
        ///
        /// When `rotateInstantly=false` and `current == orientation`,
        /// this is effectively a no-op — `orientationSpeed` stays 0.
        /// Otherwise `orientationSpeed = turningSpeed * 4` with the
        /// sign chosen by shortest arc:
        ///   diff = target - current (wrapped into [-128..127])
        ///   speed = turningSpeed * 4 (positive)
        ///   if diff is in "short arc going backwards" (i.e.
        ///   -128..0 or >128), negate `speed`.
        public static func setOrientation(
            poolIndex: Int,
            orientation: Int8,
            rotateInstantly: Bool,
            level: UInt16,
            units: inout UnitPool
        ) {
            guard poolIndex >= 0, poolIndex < UnitPool.capacity else { return }
            var u = units[poolIndex]
            guard u.isUsed, u.isAllocated else { return }
            guard let info = UnitInfo.lookup(u.type) else { return }

            if level == 0 {
                u.orientationSpeed = 0
                u.orientationTarget = orientation
                if rotateInstantly {
                    u.orientationCurrent = orientation
                } else if u.orientationCurrent != orientation {
                    var speed = Int16(info.turningSpeed) &* 4
                    let diff = Int16(orientation) &- Int16(u.orientationCurrent)
                    if (diff > -128 && diff < 0) || diff > 128 { speed = -speed }
                    u.orientationSpeed = Int8(truncatingIfNeeded: speed)
                }
            } else {
                u.turretOrientationSpeed = 0
                u.turretOrientationTarget = orientation
                if rotateInstantly {
                    u.turretOrientationCurrent = orientation
                } else if u.turretOrientationCurrent != orientation {
                    var speed = Int16(info.turningSpeed) &* 4
                    let diff = Int16(orientation) &- Int16(u.turretOrientationCurrent)
                    if (diff > -128 && diff < 0) || diff > 128 { speed = -speed }
                    u.turretOrientationSpeed = Int8(truncatingIfNeeded: speed)
                }
            }
            units[poolIndex] = u
        }

        // MARK: Speed (Unit_SetSpeed port)

        /// Port of OpenDUNE's `Unit_SetSpeed` (`src/unit.c:1902`).
        /// Computes `speed` (tile-hop clamp), `speedPerTick` (subpixel
        /// accumulator increment), and `movingSpeed` (the original
        /// 0..255 percent) from the incoming `speedPercent` and the
        /// unit's `movingSpeedFactor` table entry.
        ///
        /// Harvester rule: when amount > 0, speed scales by
        /// `(255 - amount) / 256` — loaded harvesters crawl.
        ///
        /// `gameSpeed` (0..4, default 2 = normal) drives the
        /// `Tools_AdjustToGameSpeed` adjustment. **Wingers bypass it**
        /// — air units don't respond to gameSpeed in OpenDUNE
        /// (`src/unit.c:1927`). At the default `gameSpeed == 2` the
        /// adjust is identity, so callers that don't care can leave
        /// the parameter at its default and the per-slot outputs are
        /// unchanged from the pre-port behaviour.
        @discardableResult
        public static func setSpeed(
            poolIndex: Int,
            speedPercent: UInt16,
            units: inout UnitPool,
            gameSpeed: UInt8 = 2
        ) -> Bool {
            guard poolIndex >= 0, poolIndex < UnitPool.capacity else { return false }
            var u = units[poolIndex]
            guard u.isUsed, u.isAllocated else { return false }
            guard let info = UnitInfo.lookup(u.type) else { return false }

            var speed = speedPercent

            // Harvester slowdown scales with carried amount.
            if u.type == 16 /* HARVESTER */ {
                speed = (UInt16(255) &- UInt16(u.amount)) &* speed / 256
            }

            // Reset accumulator state on every set.
            u.speed = 0
            u.speedRemainder = 0
            u.speedPerTick = 0

            if speed == 0 || speed >= 256 {
                u.movingSpeed = 0
                units[poolIndex] = u
                return true
            }

            u.movingSpeed = UInt8(truncatingIfNeeded: speed & 0xFF)

            // Apply the per-type factor (movingSpeedFactor 0..255).
            speed = UInt16(info.movingSpeedFactor) &* speed / 256

            // Ground units feel gameSpeed; wingers don't.
            if info.movementType != .winger {
                speed = Tools.adjustToGameSpeed(
                    normal: speed, minimum: 1, maximum: 255,
                    inverseSpeed: false, gameSpeed: gameSpeed
                )
            }

            // OpenDUNE splits `speed` into high-nibble × 16 (tile-hop
            // clamp) + low-nibble << 4 (subpixel increment). When the
            // high nibble is non-zero the unit is fast enough to move
            // every tick, so `speedPerTick` is pinned to 255.
            var speedPerTick = speed &<< 4
            var clampSpeed = speed &>> 4

            if clampSpeed != 0 {
                speedPerTick = 255
            } else {
                clampSpeed = 1
            }

            u.speed = UInt8(truncatingIfNeeded: clampSpeed & 0xFF)
            u.speedPerTick = UInt8(truncatingIfNeeded: speedPerTick & 0xFF)
            units[poolIndex] = u
            return true
        }

        // MARK: Harvest

        /// Slice 3 of spice income — pure-sim port of OpenDUNE's
        /// `Script_Unit_Harvest` (`src/script/unit.c:1640..1669`).
        ///
        /// Per call on a harvester standing on a spice tile: gains 0 or
        /// 1 unit of ore (`Tools_Random_256() & 1`), sets `inTransport`,
        /// clamps `amount` to 100. On ~1/32 of calls also drains 1 unit
        /// from the tile via the `changeSpice` closure — the map grid
        /// lives outside the simulation pools, so this primitive takes
        /// the reader/writer as a callback.
        ///
        /// Arguments:
        /// - `harvesterIndex`: slot in `units`.
        /// - `units`: mutated to bump amount + inTransport.
        /// - `landscapeAt`: returns the raw `LandscapeType.rawValue` for
        ///   a packed tile (reuse the same closure that
        ///   `Scripting.Host.landscapeAt` exposes).
        /// - `changeSpice`: `(packed, delta) -> Void`; called with
        ///   `delta = -1` when the tile should drain one unit. Caller
        ///   owns map storage and decides how delta translates into
        ///   thick→thin→bare transitions (mirrors
        ///   `Map_ChangeSpiceAmount` in `src/map.c:771`).
        /// - `rng`: `() -> UInt8` matching `Tools_Random_256`. Called
        ///   up to twice per invocation (amount jitter + drain gate);
        ///   tests can inject deterministic sequences.
        ///
        /// Return mirrors the C: `0` on amount-cap / off-spice / drain
        /// tick, `1` on the common "accumulated but didn't drain" path.
        ///
        /// Every meaningful step logs under the `harvest` tracer.
        @discardableResult
        public static func harvestSpiceStep(
            harvesterIndex: Int,
            units: inout UnitPool,
            landscapeAt: (UInt16) -> UInt8,
            changeSpice: (UInt16, Int16) -> Void,
            rng: () -> UInt8
        ) -> UInt16 {
            guard harvesterIndex >= 0, harvesterIndex < UnitPool.capacity else {
                Log.debug("harvest reject: index out of range (\(harvesterIndex))", tracer: .label("harvest"))
                return 0
            }
            let slot = units[harvesterIndex]
            guard slot.isUsed, slot.isAllocated, slot.type == 16 /* HARVESTER */ else {
                Log.debug("harvest reject: not a live harvester slot=\(harvesterIndex) type=\(slot.type)", tracer: .label("harvest"))
                return 0
            }
            if slot.amount >= 100 {
                Log.debug("harvest cap slot=\(harvesterIndex) amount=\(slot.amount) already full", tracer: .label("harvest"))
                return 0
            }

            let tileX = Int(slot.positionX) / 256
            let tileY = Int(slot.positionY) / 256
            guard (0..<64).contains(tileX), (0..<64).contains(tileY) else { return 0 }
            let packed = UInt16(tileY * 64 + tileX)
            let landscape = landscapeAt(packed)
            guard landscape == LandscapeType.spice.rawValue
                    || landscape == LandscapeType.thickSpice.rawValue else {
                Log.debug("harvest reject: tile=(\(tileX),\(tileY)) landscape=\(landscape) not spice", tracer: .label("harvest"))
                return 0
            }

            let jitter = rng() & 1
            var u = slot
            let amountBefore = u.amount
            u.amount = UInt8(clamping: Int(u.amount) + Int(jitter))
            if u.amount > 100 { u.amount = 100 }
            u.inTransport = true
            units[harvesterIndex] = u
            Log.info(
                "harvest slot=\(harvesterIndex) tile=(\(tileX),\(tileY)) landscape=\(landscape) amount=\(amountBefore)→\(u.amount) jitter=\(jitter) inTransport=true",
                tracer: .label("harvest")
            )

            let drainGate = rng() & 0x1F
            if drainGate != 0 {
                Log.debug("harvest slot=\(harvesterIndex) gate=\(drainGate) no-drain (returns 1)", tracer: .label("harvest"))
                return 1
            }
            changeSpice(packed, -1)
            Log.info(
                "harvest slot=\(harvesterIndex) tile=(\(tileX),\(tileY)) DRAIN -1 (returns 0)",
                tracer: .label("harvest")
            )
            return 0
        }

        // MARK: Player orders

        /// Player-issued "move to tile" order. Analogue of the path
        /// `Unit_SetAction(ACTION_MOVE)` + `Unit_SetDestination(encoded)`
        /// takes in OpenDUNE (`src/unit.c:497, 701`), collapsed to a
        /// single pure-sim write. Sets `targetMove` to the packed-tile
        /// encoded index, flips `actionID` to `move` (1), wipes any
        /// in-progress route + `currentDestination` so the scheduler's
        /// follower picks up the fresh target next tick.
        ///
        /// Returns `true` on success; `false` when the slot is
        /// unallocated / freed / out of range, or `(tileX, tileY)` is
        /// off the 64×64 map. On failure the pool is untouched.
        ///
        /// Deferred vs OpenDUNE:
        /// - `Unit_SetDestination`'s tile→unit / tile→structure upgrade
        ///   (when the target tile already holds an entity).
        /// - Harvester-on-refinery linking (sets `linkedID` via
        ///   `Object_Script_Variable4_Link`).
        /// - `nextActionID` queuing for switchType=0 actions while a
        ///   current destination is active — we always apply
        ///   immediately so the player's input feels responsive.
        /// - `Script_Reset` + `Script_Load(actionsPlayer[i])` — the
        ///   scheduler's per-slot `loadedUnitAction != actionID` check
        ///   (`Scheduler.swift:253`) reloads the engine on the next
        ///   tick at the ACTION_MOVE entry point.
        @discardableResult
        public static func orderMove(
            poolIndex: Int,
            tileX: Int,
            tileY: Int,
            units: inout UnitPool
        ) -> Bool {
            guard poolIndex >= 0, poolIndex < UnitPool.capacity else { return false }
            guard (0..<64).contains(tileX), (0..<64).contains(tileY) else { return false }
            guard units.slots[poolIndex].isUsed, units.slots[poolIndex].isAllocated else { return false }

            let packed = UInt16(tileY &* 64 &+ tileX)
            let encoded = Scripting.EncodedIndex.tile(packed: packed).raw

            var slot = units[poolIndex]
            let priorAction = slot.actionID
            let priorTarget = slot.targetMove
            slot.targetMove = encoded
            slot.actionID = Simulation.ActionID.move
            slot.currentDestinationX = 0
            slot.currentDestinationY = 0
            slot.route[0] = 0xFF
            units[poolIndex] = slot
            Log.info(
                "orderMove u\(poolIndex) (t=\(slot.type) h=\(slot.houseID)) pos=(\(slot.positionX),\(slot.positionY)) → tile=(\(tileX),\(tileY)) encoded=\(String(format: "0x%04X", encoded)) action:\(priorAction)→1 prevTarget=\(String(format: "0x%04X", priorTarget))",
                tracer: .label("move")
            )
            return true
        }

        /// Player-issued "attack this unit" order. Composes
        /// `Unit_SetAction(ACTION_ATTACK)` + `Unit_SetTarget(encoded)` from
        /// `src/unit.c:497, 1131` into a single pure-sim write — matches
        /// the path `viewport.c:140..193` runs when the player right-clicks
        /// an enemy in `SELECTIONTYPE_TARGET`.
        ///
        /// Always: writes `targetAttack = EncodedIndex.unit(targetUnitIndex)`,
        /// `actionID = attack` (0), and zeros `currentDestination{X,Y}` so
        /// the scheduler reloads the engine at the ATTACK entry-point on
        /// the next tick.
        ///
        /// Non-turret attackers (TROOPER, TRIKE, QUAD, DEVASTATOR, etc.)
        /// also get `targetMove = targetAttack` + `route[0] = 0xFF` so the
        /// chassis drives toward the target. Turreted units (TANK,
        /// SIEGE_TANK) leave `targetMove`/`route` untouched and rotate the
        /// turret in place — matches `Unit_SetTarget`'s `!hasTurret` arm
        /// at `unit.c:1161`.
        ///
        /// Returns `true` on success; `false` when either slot is out of
        /// range / unallocated / freed, the attacker has no `UnitInfo`
        /// row, or `poolIndex == targetUnitIndex` (self-attack). On
        /// failure the pool is untouched.
        ///
        /// Deferred vs OpenDUNE:
        /// - `target.blinkCounter = 8` visual cue.
        /// - Voice / sound (`Sound_StartSound(g_table_actionInfo[ACTION_ATTACK].soundID)`).
        /// - `Object_Script_Variable4_Clear`.
        /// - `Unit_SetTarget`'s tile→unit upgrade — caller already
        ///   resolved to a unit index, so no upgrade is needed here.
        /// - `Unit_FindTargetAround` snap-to-nearest — we attack the
        ///   exact unit the player clicked.
        @discardableResult
        public static func orderAttack(
            poolIndex: Int,
            targetUnitIndex: Int,
            units: inout UnitPool
        ) -> Bool {
            guard poolIndex >= 0, poolIndex < UnitPool.capacity else { return false }
            guard targetUnitIndex >= 0, targetUnitIndex < UnitPool.capacity else { return false }
            guard poolIndex != targetUnitIndex else { return false }
            guard units.slots[poolIndex].isUsed, units.slots[poolIndex].isAllocated else { return false }
            guard units.slots[targetUnitIndex].isUsed, units.slots[targetUnitIndex].isAllocated else { return false }
            guard let info = UnitInfo.lookup(units.slots[poolIndex].type) else { return false }

            let encoded = Scripting.EncodedIndex.unit(UInt16(targetUnitIndex)).raw

            var slot = units[poolIndex]
            let priorAction = slot.actionID
            let priorTarget = slot.targetAttack
            slot.targetAttack = encoded
            slot.actionID = Simulation.ActionID.attack
            slot.currentDestinationX = 0
            slot.currentDestinationY = 0
            if !info.hasTurret {
                slot.targetMove = encoded
                slot.route[0] = 0xFF
            }
            units[poolIndex] = slot
            Log.info(
                "orderAttack u\(poolIndex) (t=\(slot.type) h=\(slot.houseID) turret=\(info.hasTurret)) → target u\(targetUnitIndex) encoded=\(String(format: "0x%04X", encoded)) action:\(priorAction)→0 prevTarget=\(String(format: "0x%04X", priorTarget))",
                tracer: .label("attack")
            )
            return true
        }

        /// Player-issued attack against a structure. Same shape as
        /// `orderAttack(poolIndex:targetUnitIndex:units:)` but encodes
        /// the target as `EncodedIndex.structure(idx)` so the unit's
        /// script + target-priority math (when it lands) treats the
        /// hit as a building. Non-turret attackers also get
        /// `targetMove = encoded` + cleared route so the chassis
        /// drives toward the building; turreted units only rotate the
        /// turret. Port of OpenDUNE's `Unit_SetAction(ACTION_ATTACK) +
        /// Unit_SetTarget(encoded)` path for IT_STRUCTURE targets.
        ///
        /// Returns `false` and leaves state untouched on:
        /// - Out-of-range / unallocated attacker / target.
        /// - Attacker without a `UnitInfo` entry.
        ///
        /// The actual damage loop runs via the existing fire + bullet
        /// path once the attacker closes to `fireDistance`; structure
        /// impact damage is handled by `Simulation.Explosions.makeExplosion`.
        @discardableResult
        public static func orderAttackStructure(
            poolIndex: Int,
            targetStructureIndex: Int,
            units: inout UnitPool,
            structures: StructurePool
        ) -> Bool {
            guard poolIndex >= 0, poolIndex < UnitPool.capacity else { return false }
            guard targetStructureIndex >= 0,
                  targetStructureIndex < StructurePool.capacitySoft else { return false }
            guard units.slots[poolIndex].isUsed, units.slots[poolIndex].isAllocated else { return false }
            guard structures[targetStructureIndex].isUsed,
                  structures[targetStructureIndex].isAllocated else { return false }
            guard let info = UnitInfo.lookup(units.slots[poolIndex].type) else { return false }

            let encoded = Scripting.EncodedIndex.structure(UInt16(targetStructureIndex)).raw
            var slot = units[poolIndex]
            let priorAction = slot.actionID
            let priorTarget = slot.targetAttack
            slot.targetAttack = encoded
            slot.actionID = Simulation.ActionID.attack
            slot.currentDestinationX = 0
            slot.currentDestinationY = 0
            if !info.hasTurret {
                slot.targetMove = encoded
                slot.route[0] = 0xFF
            }
            units[poolIndex] = slot
            Log.info(
                "orderAttackStructure u\(poolIndex) (t=\(slot.type) h=\(slot.houseID) turret=\(info.hasTurret)) → structure s\(targetStructureIndex) encoded=\(String(format: "0x%04X", encoded)) action:\(priorAction)→0 prevTarget=\(String(format: "0x%04X", priorTarget))",
                tracer: .label("attack")
            )
            return true
        }

        // MARK: Unit teardown

        /// Port of `Unit_UntargetMe` (`src/unit.c:1611`). Clears any
        /// live reference to the given unit from every other unit's
        /// `targetMove` / `targetAttack` / `scriptVariable4` and from
        /// turret structures' `scriptVariables[2]`. Called right before
        /// freeing a slot so no stale encoded index survives in the
        /// pool.
        public static func untargetUnit(
            poolIndex: Int,
            host: Scripting.Host
        ) {
            guard poolIndex >= 0, poolIndex < host.units.slots.count else { return }
            let encoded = Scripting.EncodedIndex.unit(UInt16(poolIndex)).raw
            for otherIdx in 0..<host.units.slots.count {
                var u = host.units[otherIdx]
                guard u.isUsed else { continue }
                var changed = false
                if u.targetMove == encoded { u.targetMove = 0; changed = true }
                if u.targetAttack == encoded { u.targetAttack = 0; changed = true }
                if changed { host.units[otherIdx] = u }
            }
            // Turret structures read the current firing target from
            // `scriptVariables[2]`. Match `Unit_UntargetMe`'s sweep at
            // `src/unit.c:1643..1645`. Our port doesn't expose per-
            // structure script variables yet, so this is a TODO when
            // the structure script variables land.
        }

        // MARK: Structure entry

        /// Port of OpenDUNE's `Unit_EnterStructure` hostile-entry path
        /// (`src/unit.c:2226..2265`). Fires when a ground unit arrives
        /// on a structure tile owned by a different, non-allied house.
        ///
        /// Semantics:
        /// - **Saboteur** (`type == UNIT_SABOTEUR`): deal 500 damage,
        ///   remove the unit. (TODO — SOLDIER path below is the
        ///   common case; saboteur branch added when we port that
        ///   unit type.)
        /// - **Low-hp takeover** (`structure.hp < max/4`): transfer
        ///   ownership to the attacker's house. (TODO — same gate
        ///   as saboteur, deferred.)
        /// - **Otherwise** (common case — enemy foot unit on a
        ///   still-healthy structure): deal
        ///   `min(unit.hp * 2, structure.hp / 2)` damage to the
        ///   structure, remove the attacker.
        ///
        /// For the SAVE007 parity frontier this closes tick 622 —
        /// u37 (SOLDIER, hp=20) walks NE onto the player's CYARD and
        /// deals `min(40, 198) = 40` damage before being consumed.
        ///
        /// Returns `true` when the unit was consumed (caller must
        /// stop further per-tick processing for the slot).
        @discardableResult
        public static func enterStructure(
            poolIndex: Int,
            structureIndex: Int,
            host: Scripting.Host
        ) -> Bool {
            guard poolIndex >= 0, poolIndex < host.units.slots.count else { return false }
            guard structureIndex >= 0, structureIndex < host.structures.slots.count else { return false }
            let u = host.units[poolIndex]
            let s = host.structures[structureIndex]
            guard u.isUsed, u.isAllocated, s.isUsed else { return false }

            // Saboteurs / low-hp takeover paths aren't ported yet —
            // skip them so gameplay isn't affected by a half-baked
            // power-shift behaviour. The common hostile-entry damage
            // + consume branch is what SAVE007 parity needs.
            let attackerHouse = u.houseID
            let defenderHouse = s.houseID
            // Allied / same-house entry is a no-op (the OpenDUNE
            // `House_AreAllied` branch at line 2204 handles
            // REPAIR docking + linkedID chaining — not needed for
            // the parity window).
            if attackerHouse == defenderHouse { return false }

            // Damage + remove.
            let dmg = min(
                UInt16(u.hitpoints) &* 2,
                s.hitpoints / 2
            )
            Log.info(
                "enterStructure u\(poolIndex) (t=\(u.type) h=\(attackerHouse) hp=\(u.hitpoints)) onto s\(structureIndex) (t=\(s.type) h=\(defenderHouse) hp=\(s.hitpoints)) dmg=\(dmg)",
                tracer: .label("enter-structure")
            )
            _ = Simulation.Explosions.applyStructureDamage(
                structureIndex: structureIndex, damage: dmg, host: host
            )
            untargetUnit(poolIndex: poolIndex, host: host)
            host.units.free(at: poolIndex)
            return true
        }

        // MARK: Team membership

        /// Port of `Unit_AddToTeam` (`src/unit.c:540`). Writes
        /// `unit.team = teamIndex + 1` and bumps `team.members`.
        /// Returns the remaining team capacity, or 0 when either slot
        /// is invalid.
        @discardableResult
        public static func addToTeam(
            unitIndex: Int,
            teamIndex: Int,
            host: Scripting.Host
        ) -> UInt16 {
            guard unitIndex >= 0, unitIndex < host.units.slots.count,
                  teamIndex >= 0, teamIndex < host.teams.slots.count else { return 0 }
            guard host.units.slots[unitIndex].isUsed else { return 0 }
            guard host.teams.slots[teamIndex].isUsed else { return 0 }

            var u = host.units.slots[unitIndex]
            u.team = UInt8(clamping: teamIndex + 1)
            host.units[unitIndex] = u

            var t = host.teams.slots[teamIndex]
            t.members &+= 1
            host.teams[teamIndex] = t

            return t.maxMembers > t.members ? t.maxMembers - t.members : 0
        }

        /// Port of `Unit_RemoveFromTeam` (`src/unit.c:556`). When the
        /// unit has a team assignment (`team != 0`), decrements that
        /// team's member count and clears the unit's team field.
        /// Returns the team's remaining capacity, or 0 when the unit
        /// has no team.
        @discardableResult
        public static func removeFromTeam(
            unitIndex: Int,
            host: Scripting.Host
        ) -> UInt16 {
            guard unitIndex >= 0, unitIndex < host.units.slots.count else { return 0 }
            var u = host.units.slots[unitIndex]
            guard u.isUsed else { return 0 }
            if u.team == 0 { return 0 }

            let teamIdx = Int(u.team) - 1
            guard teamIdx >= 0, teamIdx < host.teams.slots.count,
                  host.teams.slots[teamIdx].isUsed else {
                // Defensive: dangling team reference → clear it and bail.
                u.team = 0
                host.units[unitIndex] = u
                return 0
            }

            var t = host.teams.slots[teamIdx]
            if t.members > 0 { t.members &-= 1 }
            host.teams[teamIdx] = t

            u.team = 0
            host.units[unitIndex] = u

            return t.maxMembers > t.members ? t.maxMembers - t.members : 0
        }

        // MARK: Helpers

        private static func isValid(encoded: Scripting.EncodedIndex, host: Scripting.Host) -> Bool {
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
