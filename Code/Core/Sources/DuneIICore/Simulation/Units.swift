import Foundation

extension Simulation {
    /// Unit-creation helpers. Mirrors OpenDUNE's `Unit_Create` /
    /// `Unit_CreateBullet` (`src/unit.c`). Namespaced under `Simulation`
    /// so both `Scripting.Functions` and test harnesses can invoke them
    /// without reaching into `UnitPool` internals.
    public enum Units {

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
            if info.movementType == .winger {
                slot.speed = 255
            }
            pool[idx] = slot
            return idx
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
            guard isValid(encoded: encoded, host: host) else { return nil }
            guard let info = UnitInfo.lookup(type) else { return nil }
            guard let targetPos = Pos32.of(encoded, host: host) else { return nil }

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
                bullet.orientationCurrent = Int8(bitPattern: orientation)
                bullet.targetAttack = target
                bullet.hitpoints = damage
                bullet.currentDestinationX = targetPos.x
                bullet.currentDestinationY = targetPos.y
                bullet.fireDelay = UInt8(truncatingIfNeeded: info.fireDistance & 0xFF)
                // OpenDUNE `Unit_Create` sets speed=255 for winger types; all
                // bullets/missiles are MOVEMENT_WINGER. Required for the
                // scheduler's route-follower to advance the bullet at a
                // meaningful rate.
                bullet.speed = 255
                // Winger targets get doubled travel budget (AA-style
                // lead-the-target behaviour, from OpenDUNE).
                if encoded.kind == .unit,
                   let targetSlot = host.unitSlot(for: encoded),
                   let targetInfo = UnitInfo.lookup(targetSlot.type),
                   targetInfo.movementType == .winger {
                    bullet.fireDelay = UInt8(clamping: UInt16(bullet.fireDelay) &* 2)
                }
                host.units[bulletIdx] = bullet
                return bulletIdx

            case 23, 24:
                // Bullet / sonic blast: step off the shooter's tile so
                // the bullet doesn't land on itself.
                let orientation = Pos32.direction(from: position, to: targetPos)
                let stepped1 = Pos32.moved(position, orientation: 0, distance: 32)
                let spawn = Pos32.moved(stepped1, orientation: orientation, distance: 128)
                guard let bulletIdx = host.units.allocateForType(type: type, houseID: houseID) else {
                    return nil
                }
                var bullet = host.units[bulletIdx]
                bullet.positionX = spawn.x
                bullet.positionY = spawn.y
                bullet.orientationCurrent = Int8(bitPattern: orientation)
                bullet.targetAttack = target
                bullet.hitpoints = damage
                bullet.currentDestinationX = targetPos.x
                bullet.currentDestinationY = targetPos.y
                if type == 24 {
                    bullet.fireDelay = UInt8(truncatingIfNeeded: info.fireDistance & 0xFF)
                }
                bullet.speed = 255
                host.units[bulletIdx] = bullet
                return bulletIdx

            default:
                return nil
            }
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
