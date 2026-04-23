import Foundation
import Memoirs

extension Simulation {
    /// Radius-damage + explosion-pool helpers. Ports of `Map_MakeExplosion`
    /// (`src/map.c:403`), `Unit_Damage` (`src/unit.c:1530`), and
    /// `Structure_Damage` (`src/structure.c:1039`), trimmed for this slice.
    /// See `Documentation/Algorithms/Explosion.md`.
    public enum Explosions {

        /// Port of `Unit_Damage` (simplified). Returns `true` when the
        /// unit was destroyed by this call. Bullets / missiles don't
        /// take damage (`isNormalUnit` guard) — matches OpenDUNE.
        ///
        /// Deferred (see Explosion.md §3): infantry→trooper halving,
        /// harvester spice spill, `ACTION_DIE` state machine, smoke flag,
        /// AI retaliation.
        @discardableResult
        public static func applyUnitDamage(
            unitIndex: Int,
            damage: UInt16,
            host: Scripting.Host
        ) -> Bool {
            guard unitIndex >= 0, unitIndex < host.units.slots.count else { return false }
            var slot = host.units[unitIndex]
            guard slot.isUsed, slot.isAllocated else { return false }

            // Only "normal" units (flags.isNormalUnit) and sandworms take
            // damage. We don't track `isNormalUnit` on the slot yet, so
            // gate by bullet-kin types that should be invulnerable.
            if isProjectile(type: slot.type) { return false }

            if damage == 0 { return false }

            let hpBefore = slot.hitpoints
            if slot.hitpoints >= damage {
                slot.hitpoints &-= damage
            } else {
                slot.hitpoints = 0
            }
            host.units[unitIndex] = slot
            Log.debug(
                "applyUnitDamage unit=\(unitIndex) type=\(slot.type) house=\(slot.houseID) hp=\(hpBefore)→\(slot.hitpoints) dmg=\(damage)",
                tracer: .label("damage")
            )

            if slot.hitpoints == 0 {
                // Capture the death visual BEFORE freeing — after free,
                // the slot's `type` / `position` are reset. OpenDUNE
                // achieves the same via the `ACTION_DIE` state machine
                // that reads `ui->explosionType` before `Unit_Remove`.
                let type = slot.type
                let deathPos = Pos32(x: slot.positionX, y: slot.positionY)
                let houseID = slot.houseID
                Log.info(
                    "unit \(unitIndex) (type \(type) house \(houseID)) destroyed by \(damage) dmg",
                    tracer: .label("damage")
                )
                host.units.free(at: unitIndex)

                if let info = UnitInfo.lookup(type),
                   info.explodeOnDeath,
                   let explosion = info.explosionType {
                    // `hitpoints: 0` → visual-only pool entry, no
                    // cascading radius damage. Matches the "tank pops
                    // with a pretty fireball but doesn't chain-kill its
                    // neighbours" behaviour of vanilla.
                    makeExplosion(
                        type: explosion,
                        position: deathPos,
                        hitpoints: 0,
                        unitOriginEncoded: 0,
                        host: host
                    )
                }
                // Infantry get a persistent corpse sprite — the type's
                // `displayMode` tells us whether it walked on foot (3-
                // or 4-frame cycle) so this detection stays cheap.
                if let info = UnitInfo.lookup(type),
                   info.displayMode == .infantry3 || info.displayMode == .infantry4
                {
                    let corpseIdx = host.explosions.add(
                        type: ExplosionType.corpseInfantry.rawValue,
                        positionX: deathPos.x,
                        positionY: deathPos.y,
                        houseID: houseID,
                        frames: 240  // ~20 seconds at 12 Hz sim tick
                    )
                    Log.info(
                        "corpse spawned type=\(type) at (\(deathPos.x),\(deathPos.y)) house=\(houseID) slot=\(corpseIdx.map(String.init) ?? "FULL") activeAfter=\(host.explosions.slots.filter { $0.isActive }.count)",
                        tracer: .label("damage")
                    )
                }
                return true
            }
            return false
        }

        /// Port of `Structure_Damage` (simplified). Returns `true` when
        /// the structure was destroyed.
        ///
        /// Deferred: score updates, `Structure_Destroy` chain (rubble,
        /// credit refund, voice), reserved-slot handling for walls.
        @discardableResult
        public static func applyStructureDamage(
            structureIndex: Int,
            damage: UInt16,
            host: Scripting.Host
        ) -> Bool {
            guard structureIndex >= 0, structureIndex < host.structures.slots.count else { return false }
            var slot = host.structures[structureIndex]
            guard slot.isUsed else { return false }
            if damage == 0 { return false }

            let hpBefore = slot.hitpoints
            if slot.hitpoints >= damage {
                slot.hitpoints &-= damage
            } else {
                slot.hitpoints = 0
            }
            host.structures[structureIndex] = slot
            Log.debug(
                "applyStructureDamage structure=\(structureIndex) type=\(slot.type) house=\(slot.houseID) hp=\(hpBefore)→\(slot.hitpoints) dmg=\(damage)",
                tracer: .label("damage")
            )

            if slot.hitpoints == 0 {
                Log.info(
                    "structure \(structureIndex) (type \(slot.type) house \(slot.houseID)) destroyed by \(damage) dmg",
                    tracer: .label("damage")
                )
                host.structures.free(at: structureIndex)
                return true
            }
            return false
        }

        /// Port of `Map_MakeExplosion` (`src/map.c:403`). Applies radius
        /// damage to every live unit within `reactionDistance`, damages
        /// the structure at the explosion's tile (if any), and queues an
        /// entry in `host.explosions`. When `hitpoints == 0`, damage is
        /// skipped and only the visual explosion is queued.
        public static func makeExplosion(
            type: UInt16,
            position: Pos32,
            hitpoints: UInt16,
            unitOriginEncoded: UInt16,
            host: Scripting.Host
        ) {
            // Type must be in 0..19.
            if type >= ExplosionType.max { return }
            Log.debug(
                "makeExplosion type=\(type) pos=(\(position.x),\(position.y)) dmg=\(hitpoints)",
                tracer: .label("explosion")
            )

            var explosionType = type
            let isDeathHand = (type == ExplosionType.deathHand.rawValue)
            let reactionDistance: UInt16 = isDeathHand ? 32 : 16
            let packed = Pathfinder.packedTile(x: position.x, y: position.y)

            // Unit-radius damage.
            if hitpoints != 0 {
                // Snapshot the findArray up front — `applyUnitDamage`
                // may `free(at:)` the slot mid-iteration, mutating it.
                for idx in host.units.findArray {
                    let unit = host.units[idx]
                    guard unit.isUsed, unit.isAllocated else { continue }
                    let unitPos = Pos32(x: unit.positionX, y: unit.positionY)
                    let d = Pos32.distance(position, unitPos) >> 4
                    if d >= reactionDistance { continue }

                    // Specific exclusions from OpenDUNE's loop.
                    if unit.type == 25 /*SANDWORM*/
                        && type == ExplosionType.sandwormSwallow.rawValue { continue }
                    if unit.type == 26 /*FRIGATE*/ { continue }

                    let shift = UInt16(min(d >> 2, 15))  // cap shift at 15
                    let dmg = hitpoints >> shift
                    _ = applyUnitDamage(unitIndex: idx, damage: dmg, host: host)
                }
            }

            // Structure-at-point damage.
            if hitpoints != 0 {
                if let sIdx = structureAt(packed: packed, host: host) {
                    let sSlot = host.structures[sIdx]
                    // IMPACT_LARGE downgrades to SMOKE_PLUME when the
                    // building is already < half HP (cosmetic).
                    if type == ExplosionType.impactLarge.rawValue,
                       let info = StructureInfo.lookup(sSlot.type),
                       info.hitpoints / 2 > sSlot.hitpoints {
                        explosionType = ExplosionType.smokePlume.rawValue
                    }
                    _ = applyStructureDamage(structureIndex: sIdx, damage: hitpoints, host: host)
                }
            }

            // Pool entry. Replace any in-progress explosion on the same tile.
            host.explosions.stopAtPosition(packed: packed)
            let originHouse = houseID(forEncoded: unitOriginEncoded, host: host)
            _ = host.explosions.add(
                type: explosionType,
                positionX: position.x,
                positionY: position.y,
                houseID: originHouse
            )
        }

        // MARK: Private helpers

        /// OpenDUNE types 18..24 are bullets / missiles. These don't
        /// take damage in `Unit_Damage` (`flags.isNormalUnit` is false
        /// in `g_table_unitInfo`). We can't yet plumb that flag, so
        /// hardcode the range.
        private static func isProjectile(type: UInt8) -> Bool {
            return (18...24).contains(type)
        }

        /// Which structure (if any) covers the packed tile. Walks
        /// `structures.findArray` and checks each footprint. Reserved
        /// slots (walls / slabs) never carry object damage in this slice.
        private static func structureAt(
            packed: UInt16,
            host: Scripting.Host
        ) -> Int? {
            let tx = Int(packed & 0x3F)
            let ty = Int((packed >> 6) & 0x3F)
            for idx in host.structures.findArray {
                let s = host.structures[idx]
                guard s.isUsed else { continue }
                guard let info = StructureInfo.lookup(s.type) else { continue }
                let sx = Int(s.positionX) >> 8
                let sy = Int(s.positionY) >> 8
                let (w, h) = info.layout.dimensions
                if tx >= sx && tx < sx + w && ty >= sy && ty < sy + h {
                    return idx
                }
            }
            return nil
        }

        private static func houseID(
            forEncoded encoded: UInt16,
            host: Scripting.Host
        ) -> UInt8 {
            let e = Scripting.EncodedIndex(raw: encoded)
            return host.houseID(of: e) ?? 0xFF
        }
    }
}
