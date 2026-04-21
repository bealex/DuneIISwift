import Foundation

extension Simulation {
    /// Structure-level helpers. Mirrors OpenDUNE's `Structure_*` family
    /// in `src/structure.c` — the read-side queries that build panels,
    /// AI evaluation, and the tick driver consume. Namespaced under
    /// `Simulation` for the same reason `Units` / `Explosions` are:
    /// keeps the pool type small and gives callers a stable entry point
    /// that doesn't reach into `StructurePool` internals.
    public enum Structures {

        /// Port of `Structure_GetStructuresBuilt` (`src/structure.c`).
        /// Returns the bitmask `OR(1 << structureType)` over every
        /// non-slab / non-wall structure of the given house currently
        /// present on the map.
        ///
        /// Slabs (types 0, 1) and walls (type 14) never contribute;
        /// they aren't prerequisites for anything and would pollute
        /// the bitmask math in `buildableStructuresFromYard`.
        ///
        /// Deviation from OpenDUNE: the C function also has a side
        /// effect (`h->windtrapCount = 0; ... if (type == WINDTRAP) h->windtrapCount++`).
        /// That's a concern for the power-consumption subsystem and
        /// lives on a different path for us. Keeping this a pure read.
        public static func structuresBuilt(houseID: UInt8, pool: StructurePool) -> UInt32 {
            var result: UInt32 = 0
            for index in pool.findArray {
                let slot = pool[index]
                guard slot.isUsed, slot.isAllocated else { continue }
                guard slot.houseID == houseID else { continue }
                let type = slot.type
                if type == 0 || type == 1 || type == 14 { continue }
                result |= UInt32(1) << UInt32(type)
            }
            return result
        }

        /// Port of the `STRUCTURE_CONSTRUCTION_YARD` case of
        /// `Structure_GetBuildable` (`src/structure.c`). Returns a
        /// bitmask `(1 << structureType)` over every type the given
        /// yard may currently queue.
        ///
        /// AI yards (`yardHouseID != playerHouseID`) skip the
        /// prerequisite check and the upgrade-level check — OpenDUNE's
        /// AI gets to build anything its campaign/house gates allow,
        /// on the theory that the mission designer placed a yard
        /// deliberately.
        ///
        /// Campaign gate promotes `availableCampaign` to signed `Int`
        /// before subtracting 1, matching OpenDUNE's C `int` integer
        /// promotion: `g_campaignID >= availableCampaign - 1`. For
        /// ROCKET_TURRET (`availableCampaign == 0`), the threshold is
        /// `-1`, so the campaign gate *passes* for any non-negative
        /// campaign — the upgrade-gate is what actually keeps it
        /// locked at player yards until level 2.
        public static func buildableStructuresFromYard(
            yardHouseID: UInt8,
            yardUpgradeLevel: UInt8,
            structuresBuilt: UInt32,
            campaignID: UInt16,
            playerHouseID: UInt8
        ) -> UInt32 {
            var result: UInt32 = 0
            let isAIYard = yardHouseID != playerHouseID

            for typeID in UInt8(0)..<UInt8(19) {
                let info = StructureInfo.table[Int(typeID)]

                var availableCampaign = info.availableCampaign
                var structuresRequired = info.structuresRequired

                // Harkonnen WOR exception: skip BARRACKS prereq and
                // pin availableCampaign to 2 from campaign 1 onward.
                if typeID == 7 /* WOR_TROOPER */
                    && yardHouseID == House.harkonnen
                    && campaignID >= 1
                {
                    structuresRequired &= ~(UInt32(1) << UInt32(10)) // clear BARRACKS bit
                    availableCampaign = 2
                }

                // Prereq gate (AI skips).
                let prereqsMet = (structuresBuilt & structuresRequired) == structuresRequired
                if !prereqsMet && !isAIYard { continue }

                // Non-Harkonnen LIGHT_VEHICLE pin: hide behind c>=1.
                if typeID == 3 /* LIGHT_VEHICLE */ && yardHouseID != House.harkonnen {
                    availableCampaign = 2
                }

                // Campaign gate: OpenDUNE C promotes both operands to
                // signed `int` before subtracting, so a 0 availableCampaign
                // yields `-1` and the gate passes for any campaign.
                let threshold = Int(availableCampaign) - 1
                if Int(campaignID) < threshold { continue }

                // House bitmask gate.
                if (info.availableHouse & (UInt8(1) << yardHouseID)) == 0 { continue }

                // Upgrade gate (AI skips).
                if yardUpgradeLevel >= info.upgradeLevelRequired || isAIYard {
                    result |= UInt32(1) << UInt32(typeID)
                }
            }

            return result
        }

        /// Port of `Structure_Allocate` (`src/pool/structure.c`).
        /// Assigns a pool slot for a new structure.
        ///
        /// - For SLAB_1x1 / SLAB_2x2 / WALL the `at` parameter is
        ///   ignored and the reserved aggregate slot is returned
        ///   (81 / 80 / 79 respectively). These slots are re-initialised
        ///   — previous content is discarded — which matches OpenDUNE's
        ///   behaviour of reusing the "one per house" aggregate.
        /// - For every other type, `at == invalidIndex` (0xFFFF) triggers
        ///   a walk of `0..<capacitySoft` for the first free slot.
        ///   Any other value is used directly; `nil` is returned if
        ///   that slot is already used.
        /// - Returns `nil` when the pool has no free normal slot.
        @discardableResult
        public static func allocate(
            at requestedIndex: UInt16,
            type: UInt8,
            houseID: UInt8,
            pool: inout StructurePool
        ) -> Int? {
            switch type {
            case 0:  // SLAB_1x1
                return pool.allocateReserved(at: StructurePool.indexSlab1x1, type: type)
            case 1:  // SLAB_2x2
                return pool.allocateReserved(at: StructurePool.indexSlab2x2, type: type)
            case 14: // WALL
                return pool.allocateReserved(at: StructurePool.indexWall, type: type)
            default:
                if requestedIndex == StructurePool.invalidIndex {
                    for i in 0..<StructurePool.capacitySoft where !pool.slots[i].isUsed {
                        return pool.allocate(at: i, type: type, houseID: houseID)
                    }
                    return nil
                }
                let i = Int(requestedIndex)
                guard i >= 0, i < StructurePool.capacitySoft, !pool.slots[i].isUsed else {
                    return nil
                }
                return pool.allocate(at: i, type: type, houseID: houseID)
            }
        }

        /// Port of `Structure_Create` (`src/structure.c`) plus the
        /// non-slab / non-wall tail of `Structure_Place`. Seeds all the
        /// fields a fresh structure needs to participate in the sim;
        /// see `Documentation/Algorithms/StructureCreate.md` §6 for the
        /// list of OpenDUNE behaviours we *don't* port yet (script
        /// reset, fog, power recalc, AI auto-upgrade, validation).
        ///
        /// Returns the pool index of the created slot, or `nil` when
        /// the type / house is out of range or the pool has no free
        /// slot.
        @discardableResult
        public static func create(
            type: UInt8,
            houseID: UInt8,
            position: Pos32,
            pool: inout StructurePool,
            tilesWithoutSlab: Int = 0
        ) -> Int? {
            guard houseID < 6 else { return nil }
            guard type < 19 else { return nil }

            guard let idx = allocate(
                at: StructurePool.invalidIndex,
                type: type,
                houseID: houseID,
                pool: &pool
            ) else { return nil }

            let info = StructureInfo.table[Int(type)]
            var slot = pool[idx]

            slot.state         = -1      // STRUCTURE_STATE_JUSTBUILT
            slot.linkedID      = 0xFF
            slot.hitpoints     = info.hitpoints
            slot.hitpointsMax  = info.hitpoints
            slot.objectType    = 0xFFFF
            slot.countDown     = 0
            slot.upgradeLevel  = 0
            slot.degrades      = false

            // Harkonnen LIGHT_VEHICLE upgradeLevel pin.
            if houseID == House.harkonnen && type == 3 /* LIGHT_VEHICLE */ {
                slot.upgradeLevel = 1
            }

            // Tile-align the anchor; OpenDUNE masks the pixel position
            // to the containing tile before writing the slot.
            slot.positionX = position.x & 0xFF00
            slot.positionY = position.y & 0xFF00

            // HP degradation when placed without a full concrete slab.
            // OpenDUNE `Structure_Place` divide-order (integer arithmetic):
            //   hitpoints -= (hitpointsMax / 2) * tilesWithoutSlab / footprintCount
            // `footprintCount` comes from the layout's tile count.
            if tilesWithoutSlab > 0 {
                let footprintCount = info.layout.footprintOffsets.count
                if footprintCount > 0 {
                    let halfMax = Int(info.hitpoints) / 2
                    let damage = halfMax * tilesWithoutSlab / footprintCount
                    slot.hitpoints = UInt16(max(0, Int(slot.hitpoints) - damage))
                    slot.degrades = true
                }
            }

            pool[idx] = slot
            return idx
        }

        /// Returns the tile coordinates covered by a structure of `type`
        /// anchored at `(anchorX, anchorY)`. Unknown type → empty.
        /// Negative / out-of-map anchors pass through unchanged; bounds
        /// checking is `isValidBuildLocation`'s job.
        public static func footprintTiles(
            type: UInt8, anchorX: Int, anchorY: Int
        ) -> [(x: Int, y: Int)] {
            guard let info = StructureInfo.lookup(type) else { return [] }
            return info.layout.footprintOffsets.map {
                (x: anchorX + $0.x, y: anchorY + $0.y)
            }
        }

        /// Partial port of `Structure_IsValidBuildLocation`
        /// (`src/structure.c`). Slices 4a–4b check:
        ///
        /// - Every footprint tile sits inside the 64×64 map.
        /// - No existing pool structure's footprint overlaps.
        /// - No unit is currently on any footprint tile.
        /// - When `landscapeAt` is non-nil: each footprint tile must
        ///   pass the `isValidForStructure` (or `isValidForStructure2`
        ///   for `notOnConcrete` structures) gate. Tiles not already
        ///   on concrete contribute to `neededSlabs`.
        ///
        /// Deferred to slice 4c (see `BuildValidationLandscape.md` §5):
        /// - HP degradation from `neededSlabs`.
        /// - Adjacent-to-player-structure rule for non-CY buildings.
        /// - Placement landscape updates (stamping LST_STRUCTURE onto
        ///   occupied tiles) — the pool overlap check is authoritative
        ///   for now.
        ///
        /// Returns:
        /// - `0`: invalid. Placement should be rejected.
        /// - `1`: valid; no slab deficit.
        /// - `-n`: valid but degraded; `n` footprint tiles lack
        ///   concrete underneath. Callers treat this as success for
        ///   slice 4b; slice 4c applies HP loss.
        public static func isValidBuildLocation(
            tileX: Int, tileY: Int,
            type: UInt8,
            structures: StructurePool,
            units: UnitPool,
            landscapeAt: ((Int, Int) -> LandscapeType)? = nil,
            playerHouseID: UInt8? = nil,
            tileHouseIDAt: ((Int, Int) -> UInt8)? = nil
        ) -> Int16 {
            let footprint = footprintTiles(type: type, anchorX: tileX, anchorY: tileY)
            if footprint.isEmpty { return 0 }
            guard let structureInfo = StructureInfo.lookup(type) else { return 0 }

            var neededSlabs = 0

            for (fx, fy) in footprint {
                // Bounds.
                if fx < 0 || fx >= 64 || fy < 0 || fy >= 64 { return 0 }

                // Landscape gate (4b). Skipped when no closure provided.
                if let landscapeAt {
                    let lst = landscapeAt(fx, fy)
                    let info = LandscapeInfo.lookup(lst)
                    if structureInfo.notOnConcrete {
                        if !info.isValidForStructure2 { return 0 }
                    } else {
                        if !info.isValidForStructure { return 0 }
                        if lst != .concreteSlab { neededSlabs &+= 1 }
                    }
                }
            }

            // Structure overlap: walk the non-reserved findArray and
            // expand each entry to its own footprint for the intersect
            // test. Reserved slabs/walls live on the map tiles rather
            // than in `findArray`, so they're naturally skipped here.
            for idx in structures.findArray {
                let slot = structures[idx]
                guard slot.isUsed, slot.isAllocated else { continue }
                let ax = Int(slot.positionX) / 256
                let ay = Int(slot.positionY) / 256
                let existing = footprintTiles(type: slot.type, anchorX: ax, anchorY: ay)
                for (ex, ey) in existing {
                    for (fx, fy) in footprint where ex == fx && ey == fy {
                        return 0
                    }
                }
            }

            // Unit overlap: each unit occupies one tile at
            // `positionX/Y >> 8`. Bullets / projectiles also occupy
            // tiles — OpenDUNE's `Object_GetByPackedTile` doesn't
            // distinguish, so we don't either. Build panel blocking
            // because a bullet is mid-flight on the target tile is
            // weird but faithful.
            for idx in units.findArray {
                let slot = units.slots[idx]
                guard slot.isUsed, slot.isAllocated else { continue }
                let ux = Int(slot.positionX) / 256
                let uy = Int(slot.positionY) / 256
                for (fx, fy) in footprint where ux == fx && uy == fy {
                    return 0
                }
            }

            // Adjacent-to-player-base gate (4c). Only applies to
            // non-CY placements when the caller knows which house the
            // player is. Needs the landscape closure for the
            // slab/wall fallback. See `BuildValidationAdjacency.md`.
            if let playerHouseID, type != 8 /* CYARD */, let landscapeAt {
                var adjacencyOK = false
                for (dx, dy) in structureInfo.layout.adjacentOffsets {
                    let nx = tileX + dx
                    let ny = tileY + dy
                    guard (0..<64).contains(nx), (0..<64).contains(ny) else { continue }

                    // Player-owned structure at the tile?
                    if let owner = structureOwnerAt(pool: structures, tileX: nx, tileY: ny),
                       owner == playerHouseID
                    {
                        adjacencyOK = true
                        break
                    }

                    // Player-owned concrete slab or wall via tile houseID?
                    let lst = landscapeAt(nx, ny)
                    if (lst == .concreteSlab || lst == .wall),
                       let tileHouseIDAt,
                       tileHouseIDAt(nx, ny) == playerHouseID
                    {
                        adjacencyOK = true
                        break
                    }
                }
                if !adjacencyOK { return 0 }
            }

            if neededSlabs == 0 { return 1 }
            return -Int16(neededSlabs)
        }

        /// Per-tick countdown decrement used by `tickConstruction`.
        /// Matches OpenDUNE's `buildSpeed = 256` at standard game
        /// speed — combined with `countDown = buildTime << 8`, one
        /// `buildTime` unit drains in one scheduler tick. Slice 4d+
        /// will scale by house / game-speed factors.
        public static let defaultBuildSpeed: UInt16 = 256

        /// Port of the post-factory-window tail of `Structure_BuildObject`
        /// for CONSTRUCTION_YARD yards: flip the yard into `BUSY` with
        /// `objectType = type` and `countDown = buildTime << 8`.
        /// Returns `true` on success. Rejects: non-yard slots, yards
        /// that are already `BUSY`, out-of-range `objectType`, or
        /// freed / reserved slots.
        ///
        /// Deferred vs OpenDUNE (see `StructureConstruction.md` §3):
        /// - No pre-allocated placeholder / linkedID dance — the
        ///   `Structure_Create` happens at placement-commit instead.
        /// - No credit drain.
        /// - No `onHold` / `Structure_CancelBuild`.
        /// - No upgrade or starport branches.
        @discardableResult
        public static func startConstruction(
            yardIndex: Int,
            objectType: UInt8,
            pool: inout StructurePool
        ) -> Bool {
            guard yardIndex >= 0, yardIndex < StructurePool.capacitySoft else { return false }
            let slot = pool[yardIndex]
            guard slot.isUsed, slot.isAllocated else { return false }
            guard slot.type == 8 /* CONSTRUCTION_YARD */ else { return false }
            guard slot.state != StructureState.busy.rawValue else { return false }
            guard let info = StructureInfo.lookup(objectType) else { return false }

            var updated = slot
            updated.objectType = UInt16(objectType)
            updated.countDown = info.buildTime &<< 8
            updated.state = StructureState.busy.rawValue
            pool[yardIndex] = updated
            return true
        }

        /// Port of the `countDown` decrement from OpenDUNE's
        /// `GameLoop_Structure`. For every BUSY yard in the pool's
        /// `findArray`: subtract `defaultBuildSpeed` from `countDown`;
        /// when `countDown` would reach zero, clamp + flip `state` to
        /// `READY`. IDLE / JUSTBUILT / READY slots are untouched.
        ///
        /// Deferred: credit drain (per-tick house spend), game-speed
        /// scaling, and the `Structure_CancelBuild` path.
        public static func tickConstruction(pool: inout StructurePool) {
            let step = defaultBuildSpeed
            for idx in pool.findArray {
                let slot = pool[idx]
                guard slot.isUsed, slot.isAllocated else { continue }
                guard slot.state == StructureState.busy.rawValue else { continue }
                var updated = slot
                if updated.countDown > step {
                    updated.countDown &-= step
                } else {
                    updated.countDown = 0
                    updated.state = StructureState.ready.rawValue
                }
                pool[idx] = updated
            }
        }

        /// Walks the non-reserved structure pool and returns the
        /// houseID of the structure whose footprint covers `(tileX,
        /// tileY)`, or nil when none does. Used by the adjacency gate
        /// and by tests.
        private static func structureOwnerAt(
            pool: StructurePool, tileX: Int, tileY: Int
        ) -> UInt8? {
            for idx in pool.findArray {
                let slot = pool[idx]
                guard slot.isUsed, slot.isAllocated else { continue }
                let ax = Int(slot.positionX) / 256
                let ay = Int(slot.positionY) / 256
                let existing = footprintTiles(type: slot.type, anchorX: ax, anchorY: ay)
                for (ex, ey) in existing where ex == tileX && ey == tileY {
                    return slot.houseID
                }
            }
            return nil
        }
    }
}
