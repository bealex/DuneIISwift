import Foundation

extension Simulation {
    /// Target selection — `Unit_FindBestTargetEncoded` and the priority
    /// math feeding it. Pure reads over the pools plus one side-effect:
    /// `FindBestTargetUnit` stamps the attacker's `originEncoded` on the
    /// first call (when it's zero), mirroring OpenDUNE.
    ///
    /// See `Documentation/Algorithms/TargetAcquisition.md`.
    public enum TargetAcquisition {

        /// Decodes an `IT_TILE`-kind encoded index back to a tile-center
        /// pos32. Matches `Tile_UnpackTile(Tools_Index_Decode(encoded))`.
        /// For non-tile encoded values, returns the corresponding pool
        /// slot's position (mirrors `Tools_Index_GetTile`).
        private static func unpackTileCenter(encoded: UInt16) -> Pos32 {
            let packed = Scripting.EncodedIndex(raw: encoded).decoded
            let x = packed & 0x3F
            let y = (packed >> 6) & 0x3F
            return Pos32(x: x &* 256 &+ 128, y: y &* 256 &+ 128)
        }

        // MARK: Priority

        /// Port of `Unit_GetTargetUnitPriority` (`src/unit.c:743`).
        /// Zero means "don't shoot it". Positive means "shoot it,
        /// higher is better". Clamped at `0x7D00`.
        public static func targetUnitPriority(
            attacker: UnitSlot,
            target: UnitSlot,
            host: Scripting.Host
        ) -> UInt16 {
            // Self, freed, or not-allocated → 0.
            if attacker.index == target.index { return 0 }
            if !target.isUsed || !target.isAllocated { return 0 }
            // Attacker must have seen target.
            if (target.seenByHouses & (UInt8(1) &<< attacker.houseID)) == 0 { return 0 }
            // Allied → no attack.
            if House.areAllied(attacker.houseID, target.houseID, playerHouseID: host.playerHouseID) {
                return 0
            }

            guard let attackerInfo = UnitInfo.lookup(attacker.type),
                  let targetInfo = UnitInfo.lookup(target.type) else { return 0 }

            // Target must be targetable.
            if !targetInfo.priority { return 0 }

            let targetPacked = Pathfinder.packedTile(x: target.positionX, y: target.positionY)
            let attackerPacked = Pathfinder.packedTile(x: attacker.positionX, y: attacker.positionY)

            // Winger gate: attacker needs `targetAir`; and player-owned
            // wingers hidden by fog are unshootable.
            if targetInfo.movementType == .winger {
                if !attackerInfo.targetAir { return 0 }
                if let player = host.playerHouseID, target.houseID == player {
                    let unveiled = host.isPositionUnveiled?(targetPacked) ?? true
                    if !unveiled { return 0 }
                }
            }

            // Target must be on-map.
            let targetValid = host.isValidPosition?(targetPacked) ?? true
            if !targetValid { return 0 }

            let attackerPos = Pos32(x: attacker.positionX, y: attacker.positionY)
            let targetPos = Pos32(x: target.positionX, y: target.positionY)
            let distance = Pos32.distanceRoundedUp(attackerPos, targetPos)

            // Attacker off-map caps by TARGET's fireDistance (sic).
            let attackerValid = host.isValidPosition?(attackerPacked) ?? true
            if !attackerValid {
                if targetInfo.fireDistance >= distance { return 0 }
            }

            var priority: UInt32 = UInt32(targetInfo.priorityTarget) &+ UInt32(targetInfo.priorityBuild)
            if distance != 0 {
                priority = (priority / UInt32(distance)) &+ 1
            }

            if priority > 0x7D00 { return 0x7D00 }
            return UInt16(truncatingIfNeeded: priority)
        }

        /// Port of `Unit_GetTargetStructurePriority` (`src/unit.c:2562`).
        /// Clamped at `32000`.
        public static func targetStructurePriority(
            attacker: UnitSlot,
            target: StructureSlot,
            host: Scripting.Host
        ) -> UInt16 {
            if House.areAllied(attacker.houseID, target.houseID, playerHouseID: host.playerHouseID) {
                return 0
            }
            // Attacker must have seen the structure. Structure slots don't
            // currently carry a `seenByHouses` mask — treat "always seen"
            // for now; matches the scenario-start expected behaviour.
            // TODO: plumb seenByHouses on StructureSlot when fog lands.

            guard let info = StructureInfo.lookup(target.type) else { return 0 }

            let attackerPos = Pos32(x: attacker.positionX, y: attacker.positionY)
            let targetPos = Pos32(x: target.positionX, y: target.positionY)
            let distance = Pos32.distanceRoundedUp(attackerPos, targetPos)

            var priority: UInt32 = UInt32(info.priorityBuild) &+ UInt32(info.priorityTarget)
            if distance != 0 {
                priority = priority / UInt32(distance)
            }
            return priority > 32000 ? 32000 : UInt16(truncatingIfNeeded: priority)
        }

        // MARK: Best target — per kind

        /// Port of `Unit_FindBestTargetUnit` (`src/unit.c:923`). Scans
        /// `host.units` under the mode gate; returns the pool index of
        /// the highest-priority target, or `nil` when none found.
        ///
        /// **Side effect**: when `attacker.originEncoded == 0`, stamps
        /// the attacker's current tile into `originEncoded` (writes back
        /// through `host.units`). Matches OpenDUNE exactly.
        public static func findBestTargetUnit(
            attackerIndex: Int,
            mode: UInt16,
            host: Scripting.Host
        ) -> Int? {
            guard attackerIndex >= 0, attackerIndex < host.units.slots.count else { return nil }
            let attacker = host.units.slots[attackerIndex]
            guard attacker.isUsed, attacker.isAllocated else { return nil }

            // Resolve the "origin" tile used by mode 2 and stamp on first use.
            let originPos: Pos32
            if attacker.originEncoded == 0 {
                let packed = Pathfinder.packedTile(x: attacker.positionX, y: attacker.positionY)
                var updated = attacker
                updated.originEncoded = Scripting.EncodedIndex.tile(packed: packed).raw
                host.units[attackerIndex] = updated
                originPos = Pos32(x: attacker.positionX, y: attacker.positionY)
            } else {
                originPos = unpackTileCenter(encoded: attacker.originEncoded)
            }

            guard let attackerInfo = UnitInfo.lookup(attacker.type) else { return nil }
            var distanceLimit = UInt32(attackerInfo.fireDistance) &<< 8
            if mode == 2 { distanceLimit &<<= 1 }

            var best: Int?
            var bestPriority: Int32 = 0

            var query = PoolQuery()
            while let candidate = host.units.next(&query) {
                if mode != 0 && mode != 4 {
                    let candPos = Pos32(x: candidate.positionX, y: candidate.positionY)
                    if mode == 1 {
                        let attackerPos = Pos32(x: attacker.positionX, y: attacker.positionY)
                        if UInt32(Pos32.distance(attackerPos, candPos)) > distanceLimit { continue }
                    } else if mode == 2 {
                        if UInt32(Pos32.distance(originPos, candPos)) > distanceLimit { continue }
                    }
                }

                let priority = Int32(targetUnitPriority(attacker: attacker, target: candidate, host: host))
                if priority > bestPriority {
                    best = Int(candidate.index)
                    bestPriority = priority
                }
            }

            return bestPriority == 0 ? nil : best
        }

        /// Port of `Unit_FindBestTargetStructure` (`src/unit.c:2275`).
        /// Skips slabs (types 0, 1) and walls (type 14). Returns the
        /// pool index of the best target or `nil`.
        public static func findBestTargetStructure(
            attackerIndex: Int,
            mode: UInt16,
            host: Scripting.Host
        ) -> Int? {
            guard attackerIndex >= 0, attackerIndex < host.units.slots.count else { return nil }
            let attacker = host.units.slots[attackerIndex]
            guard attacker.isUsed, attacker.isAllocated else { return nil }

            // Origin tile — OpenDUNE assumes originEncoded is already
            // stamped; we don't re-stamp here. Fall back to attacker.pos.
            let originPos: Pos32 = attacker.originEncoded != 0
                ? unpackTileCenter(encoded: attacker.originEncoded)
                : Pos32(x: attacker.positionX, y: attacker.positionY)

            guard let attackerInfo = UnitInfo.lookup(attacker.type) else { return nil }
            let distanceLimit = UInt32(attackerInfo.fireDistance) &<< 8

            var best: Int?
            var bestPriority: UInt16 = 0

            var query = PoolQuery()
            while let candidate = host.structures.next(&query) {
                // Skip slabs / walls.
                if candidate.type == 0 || candidate.type == 1 || candidate.type == 14 { continue }
                guard let info = StructureInfo.lookup(candidate.type) else { continue }

                let diff = StructureInfo.layoutTileDiff(info.layout)
                let curPos = Pos32(
                    x: candidate.positionX &+ diff.x,
                    y: candidate.positionY &+ diff.y
                )

                if mode != 0 && mode != 4 {
                    if mode == 1 {
                        let attackerPos = Pos32(x: attacker.positionX, y: attacker.positionY)
                        if UInt32(Pos32.distance(attackerPos, curPos)) > distanceLimit { continue }
                    } else if mode == 2 {
                        if UInt32(Pos32.distance(originPos, curPos)) > distanceLimit &<< 1 { continue }
                    } else {
                        continue
                    }
                }

                let priority = targetStructurePriority(attacker: attacker, target: candidate, host: host)
                if priority >= bestPriority {
                    best = Int(candidate.index)
                    bestPriority = priority
                }
            }

            return bestPriority == 0 ? nil : best
        }

        // MARK: Sandworm targeting

        /// Port of `Unit_Sandworm_GetTargetPriority` (`src/unit.c:987`).
        /// Sandworms pick heavier, slower-moving prey on sand. Bonuses:
        /// ×4 when the target is moving or mid-fire; ×2 when within 2
        /// tiles. Units on rock / mountain / wall score 0.
        ///
        /// Deferred: the `isSandAtPosition` gate — our simulation doesn't
        /// yet surface landscape type at the Host boundary. Until then
        /// we treat all tiles as sand-eligible; when mission 5 lands and
        /// worms appear, wire `host.isSandAtPosition` and add the check.
        public static func sandwormTargetPriority(
            attacker: UnitSlot,
            target: UnitSlot,
            host: Scripting.Host
        ) -> UInt16 {
            if !target.isUsed || !target.isAllocated { return 0 }
            // Fog: if a fog predicate is wired, respect it.
            let packed = Pathfinder.packedTile(x: target.positionX, y: target.positionY)
            if let unveiled = host.isPositionUnveiled, !unveiled(packed) { return 0 }

            guard let ti = UnitInfo.lookup(target.type) else { return 0 }
            var res: UInt32 = 0
            switch ti.movementType {
            case .foot:      res = 0x64
            case .tracked:   res = 0x3E8
            case .harvester: res = 0x3E8
            case .wheeled:   res = 0x1388
            default:         res = 0
            }
            if target.speed != 0 || target.fireDelay != 0 { res &*= 4 }

            let ap = Pos32(x: attacker.positionX, y: attacker.positionY)
            let tp = Pos32(x: target.positionX, y: target.positionY)
            let distance = UInt32(Pos32.distanceRoundedUp(ap, tp))
            if distance != 0 && res != 0 { res /= distance }
            if distance < 2 { res &*= 2 }

            return res > 0xFFFF ? 0xFFFF : UInt16(truncatingIfNeeded: res)
        }

        /// Port of `Unit_Sandworm_FindBestTarget` (`src/unit.c:1020`).
        /// Walks the unit pool, returns the pool index of the highest-
        /// priority target (`>=` tie-break — later-allocated wins). Nil
        /// when no viable prey exists.
        public static func sandwormFindBestTarget(
            attackerIndex: Int,
            host: Scripting.Host
        ) -> Int? {
            guard attackerIndex >= 0, attackerIndex < host.units.slots.count else { return nil }
            let attacker = host.units.slots[attackerIndex]
            guard attacker.isUsed, attacker.isAllocated else { return nil }

            var best: Int?
            var bestPriority: UInt16 = 0
            var query = PoolQuery()
            while let u = host.units.next(&query) {
                let p = sandwormTargetPriority(attacker: attacker, target: u, host: host)
                if p >= bestPriority {
                    best = Int(u.index)
                    bestPriority = p
                }
            }
            return bestPriority == 0 ? nil : best
        }

        // MARK: Dispatcher

        /// Port of `Unit_FindBestTargetEncoded` (`src/unit.c:2396`).
        /// Returns the encoded index of the best target or `0` when none
        /// is suitable.
        public static func findBestTargetEncoded(
            attackerIndex: Int,
            mode: UInt16,
            host: Scripting.Host
        ) -> UInt16 {
            guard attackerIndex >= 0, attackerIndex < host.units.slots.count else { return 0 }
            let attacker = host.units.slots[attackerIndex]
            guard attacker.isUsed, attacker.isAllocated else { return 0 }

            // Deviator: `UNIT_DEVIATOR == 8`. Never target structures.
            let isDeviator = attacker.type == 8

            if mode == 4 {
                if let sIndex = findBestTargetStructure(attackerIndex: attackerIndex, mode: mode, host: host) {
                    return Scripting.EncodedIndex.structure(UInt16(sIndex)).raw
                }
                if let uIndex = findBestTargetUnit(attackerIndex: attackerIndex, mode: mode, host: host) {
                    return Scripting.EncodedIndex.unit(UInt16(uIndex)).raw
                }
                return 0
            }

            let uIndex = findBestTargetUnit(attackerIndex: attackerIndex, mode: mode, host: host)
            let sIndex = isDeviator ? nil : findBestTargetStructure(attackerIndex: attackerIndex, mode: mode, host: host)

            if let uIndex, let sIndex {
                // Re-read the attacker after `FindBestTargetUnit`'s origin-stamp
                // side-effect so priority math sees the live slot.
                let attackerNow = host.units.slots[attackerIndex]
                let unitTarget = host.units.slots[uIndex]
                let structureTarget = host.structures.slots[sIndex]
                let unitPriority = targetUnitPriority(attacker: attackerNow, target: unitTarget, host: host)
                let structurePriority = targetStructurePriority(attacker: attackerNow, target: structureTarget, host: host)
                if structurePriority >= unitPriority {
                    return Scripting.EncodedIndex.structure(UInt16(sIndex)).raw
                }
                return Scripting.EncodedIndex.unit(UInt16(uIndex)).raw
            }
            if let uIndex {
                return Scripting.EncodedIndex.unit(UInt16(uIndex)).raw
            }
            if let sIndex {
                return Scripting.EncodedIndex.structure(UInt16(sIndex)).raw
            }
            return 0
        }
    }
}
