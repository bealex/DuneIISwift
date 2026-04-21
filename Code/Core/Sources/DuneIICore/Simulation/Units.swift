import Foundation

extension Simulation {
    /// Unit-creation helpers. Mirrors OpenDUNE's `Unit_Create` /
    /// `Unit_CreateBullet` (`src/unit.c`). Namespaced under `Simulation`
    /// so both `Scripting.Functions` and test harnesses can invoke them
    /// without reaching into `UnitPool` internals.
    public enum Units {

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
