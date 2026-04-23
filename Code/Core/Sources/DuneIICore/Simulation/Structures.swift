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

        /// Port of the factory cases of `Structure_GetBuildable`
        /// (`src/structure.c`): LIGHT_VEHICLE (3), HEAVY_VEHICLE (4),
        /// HIGH_TECH (5), WOR_TROOPER (7), BARRACKS (10). Returns a
        /// bitmask `(1 << unitType)` over every UNIT this factory may
        /// currently produce.
        ///
        /// Gates:
        /// - `StructureInfo.buildableUnits[i]` must name a valid unit.
        /// - Unit's `structuresRequired` must be satisfied by
        ///   `structuresBuilt`.
        /// - Unit's `availableHouse` bitmask must include the factory
        ///   house.
        /// - Factory `upgradeLevel` must meet `unit.upgradeLevelRequired`.
        ///
        /// Two Ordos quirks ported verbatim:
        /// - TRIKE → RAIDER_TRIKE substitution for Ordos-owned LV
        ///   factories.
        /// - SIEGE_TANK `upgradeLevelRequired -= 1` (so 3 → 2) for
        ///   Ordos-owned HV factories.
        ///
        /// CONSTRUCTION_YARD (8), STARPORT (11), and non-factory types
        /// return 0. STARPORT is dynamic — its inventory changes over
        /// a mission as the player orders units and frigates arrive;
        /// query `starportBuildableUnits(inventory:houseID:)` for the
        /// current bitmask instead (the OpenDUNE `-1` sentinel collapses
        /// onto a dedicated entry point in Swift's unsigned world).
        public static func buildableUnitsFromFactory(
            factoryType: UInt8,
            factoryHouseID: UInt8,
            factoryUpgradeLevel: UInt8,
            structuresBuilt: UInt32
        ) -> UInt32 {
            switch factoryType {
            case 3, 4, 5, 7, 10: break
            default: return 0
            }
            guard let info = StructureInfo.lookup(factoryType) else { return 0 }

            var result: UInt32 = 0
            for slotIndex in 0..<8 {
                var unitType = info.buildableUnits[slotIndex]
                if unitType == 0xFF { continue }

                // Ordos TRIKE → RAIDER_TRIKE substitution.
                if unitType == 13 /* TRIKE */ && factoryHouseID == House.ordos {
                    unitType = 14 /* RAIDER_TRIKE */
                }

                guard let unitInfo = UnitInfo.lookup(unitType) else { continue }
                var upgradeLevelRequired = unitInfo.upgradeLevelRequired

                // Ordos SIEGE_TANK gets upgradeLevelRequired -= 1.
                if unitType == 10 /* SIEGE_TANK */ && factoryHouseID == House.ordos
                    && upgradeLevelRequired > 0
                {
                    upgradeLevelRequired -= 1
                }

                if (structuresBuilt & unitInfo.structuresRequired) != unitInfo.structuresRequired {
                    continue
                }
                if (unitInfo.availableHouse & (UInt8(1) << factoryHouseID)) == 0 { continue }
                if factoryUpgradeLevel < upgradeLevelRequired { continue }

                result |= UInt32(1) << UInt32(unitType)
            }
            return result
        }

        /// STARPORT slice of `Structure_GetBuildable` (`src/structure.c:1495..1525`).
        /// OpenDUNE returns the `-1` sentinel and the caller walks
        /// `g_starportAvailable[0..UNIT_MAX]` to build the visible-unit
        /// list. We collapse both steps here: given the live inventory
        /// (stock per unit-type; positive counts = orderable, -1 in
        /// OpenDUNE means "unknown/pending first frigate") and the
        /// house's `availableHouse` gate, emit the bitmask of types the
        /// player may add to a CHOAM order this session.
        ///
        /// The inventory is treated as an opaque count vector — the
        /// caller owns whether it came from `Scenario.choamInventory`
        /// at load, got mutated by an order commit, or was patched by
        /// a frigate-arrival event.
        public static func starportBuildableUnits(
            inventory: [Int16], houseID: UInt8
        ) -> UInt32 {
            var result: UInt32 = 0
            let houseBit = UInt8(1) << houseID
            // Walk every entry; positive stock makes a unit orderable
            // provided the house is allowed to field it.
            for (typeIDRaw, stock) in inventory.enumerated() {
                guard stock > 0 else { continue }
                let typeID = UInt8(truncatingIfNeeded: typeIDRaw)
                guard let info = UnitInfo.lookup(typeID) else { continue }
                if (info.availableHouse & houseBit) == 0 { continue }
                result |= UInt32(1) << UInt32(typeID)
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
            // Slice 5b: CYARD (8) OR any of the 5 factories (3, 4, 5, 7, 10).
            // STARPORT (11) deferred; refinery / palace / turret etc. not
            // production facilities.
            switch slot.type {
            case 3, 4, 5, 7, 8, 10: break
            default: return false
            }
            guard slot.state != StructureState.busy.rawValue else { return false }

            // Countdown source — dispatch by yard kind:
            // - CYARD (8): produced structure's `buildTime`, matching
            //   OpenDUNE's `oi = &g_table_structureInfo[objectType].o`.
            // - Factory (3, 4, 5, 7, 10): produced unit's `buildTime`
            //   (slice 5b-build). E.g. BARRACKS building SOLDIER gets
            //   SOLDIER's 32, not BARRACKS's 72.
            let buildTime: UInt16
            if slot.type == 8 {
                guard objectType < 19 else { return false }
                guard let info = StructureInfo.lookup(objectType) else { return false }
                buildTime = info.buildTime
            } else {
                guard objectType < 27 else { return false }
                guard let info = UnitInfo.lookup(objectType) else { return false }
                buildTime = info.buildTime
            }

            var updated = slot
            updated.objectType = UInt16(objectType)
            updated.countDown = buildTime &<< 8
            updated.state = StructureState.busy.rawValue
            pool[yardIndex] = updated
            Log.info(
                "startConstruction yard=\(yardIndex) yardType=\(slot.type) house=\(slot.houseID) produce=\(objectType) buildTime=\(buildTime) state=IDLE→BUSY",
                tracer: .label("construction")
            )
            return true
        }

        /// Slice 5c: tile a factory should spawn its produced unit at.
        /// Heuristic: the tile directly south of the footprint's
        /// south-west corner (`anchorY + height`). On out-of-bounds
        /// falls back to the anchor, which visually overlaps the
        /// building — acceptable for corner-of-map factories (rare).
        /// Unknown yard type falls back to the anchor too.
        ///
        /// Deliberate approximation of OpenDUNE's richer rally logic
        /// (collision-aware exit + player-set rally point); slice 5c
        /// doesn't yet surface rally-point clicks.
        public static func factorySpawnTile(
            yardType: UInt8, anchorX: Int, anchorY: Int
        ) -> (x: Int, y: Int) {
            guard let info = StructureInfo.lookup(yardType) else {
                return (anchorX, anchorY)
            }
            let exitY = anchorY + info.layout.dimensions.height
            if exitY >= 0, exitY < 64 {
                return (anchorX, exitY)
            }
            return (anchorX, anchorY)
        }

        /// Slice 5c + 6b: cancel a BUSY / READY yard's construction.
        /// Resets `state` to IDLE, clears `objectType` and `countDown`.
        /// Returns `false` on IDLE yards / out-of-range / freed slots.
        ///
        /// Slice 6b: on CY cancel (yard type 8), refunds credits
        /// proportional to progress. Port of OpenDUNE's
        /// `Structure_CancelBuild` formula:
        /// `refund = (buildTime - countDown >> 8) × buildCredits / buildTime`.
        /// Factory refund requires `UnitInfo.buildCredits` — deferred
        /// to slice 6c.
        @discardableResult
        public static func cancelConstruction(
            yardIndex: Int,
            pool: inout StructurePool,
            houses: inout HousePool
        ) -> Bool {
            guard yardIndex >= 0, yardIndex < StructurePool.capacitySoft else { return false }
            let slot = pool[yardIndex]
            guard slot.isUsed, slot.isAllocated else { return false }
            guard slot.state == StructureState.busy.rawValue
                || slot.state == StructureState.ready.rawValue
            else { return false }

            // Refund — dispatch by yard kind. Slice 6b handled CY via
            // StructureInfo; slice 6c extends to factories via UnitInfo.
            // Formula from `Structure_CancelBuild`:
            // refund = ticksSpent × buildCredits / buildTime.
            if let (buildCredits, buildTime) = producedCost(slot: slot),
               buildTime > 0
            {
                let houseIdx = Int(slot.houseID)
                if houseIdx >= 0, houseIdx < HousePool.capacity,
                   houses.slots[houseIdx].isUsed
                {
                    let ticksSpent = Int(buildTime) - Int(slot.countDown >> 8)
                    let refund = max(0, ticksSpent) * Int(buildCredits) / Int(buildTime)
                    var h = houses[houseIdx]
                    h.credits = UInt16(clamping: Int(h.credits) + refund)
                    houses[houseIdx] = h
                }
            }

            var updated = slot
            updated.state = StructureState.idle.rawValue
            updated.objectType = 0xFFFF
            updated.countDown = 0
            pool[yardIndex] = updated
            Log.info(
                "cancelConstruction yard=\(yardIndex) yardType=\(slot.type) house=\(slot.houseID) priorState=\(slot.state) priorType=\(slot.objectType) countDown=\(slot.countDown)→0",
                tracer: .label("construction")
            )
            return true
        }

        /// Slice 5b-build: flushes a READY factory — spawns the
        /// queued unit at the yard's `factorySpawnTile` exit and
        /// returns the yard to IDLE. CY completion stays on the
        /// click-map-to-place path (see `commitPlacement` in
        /// `ScenarioScene`), so this function returns `nil` for CY
        /// yards.
        ///
        /// Returns the new unit's pool index on success, or `nil`
        /// when the yard isn't a READY factory or the unit pool is
        /// full. On failure the yard is left untouched so the player
        /// can retry later.
        ///
        /// Rally point (our-own feature, not in OpenDUNE): when the
        /// yard's `rallyPointPacked != 0xFFFF`, the freshly-spawned
        /// unit gets an immediate `Units.orderMove` to the rally
        /// tile. Failure of the move order (e.g. off-map rally) is
        /// silently ignored — the unit just sits at the exit tile,
        /// same as the no-rally case.
        ///
        /// Deferred:
        /// - `Structure_BuildObject`'s linkedID dance.
        /// - Credit payment / deduction.
        /// - Audio cues, text display.
        @discardableResult
        public static func completeConstruction(
            yardIndex: Int,
            pool: inout StructurePool,
            unitPool: inout UnitPool
        ) -> Int? {
            guard yardIndex >= 0, yardIndex < StructurePool.capacitySoft else { return nil }
            let slot = pool[yardIndex]
            guard slot.isUsed, slot.isAllocated else { return nil }
            // CY completion goes through the scene's click-to-place
            // path, not here.
            switch slot.type {
            case 3, 4, 5, 7, 10: break
            default: return nil
            }
            guard slot.state == StructureState.ready.rawValue else { return nil }
            let unitType = UInt8(truncatingIfNeeded: slot.objectType)
            guard unitType < 27 else { return nil }

            let ax = Int(slot.positionX) / 256
            let ay = Int(slot.positionY) / 256
            let exit = factorySpawnTile(yardType: slot.type, anchorX: ax, anchorY: ay)
            guard let unitIdx = Units.createUnit(
                type: unitType, houseID: slot.houseID,
                tileX: exit.x, tileY: exit.y, pool: &unitPool
            ) else {
                Log.warning(
                    "completeConstruction yard=\(yardIndex) FAILED: unit pool full (type=\(unitType))",
                    tracer: .label("construction")
                )
                return nil  // pool full; leave yard READY for retry
            }
            Log.info(
                "completeConstruction yard=\(yardIndex) yardType=\(slot.type) house=\(slot.houseID) spawned unit=\(unitIdx) type=\(unitType) at tile=(\(exit.x),\(exit.y))",
                tracer: .label("construction")
            )

            if slot.rallyPointPacked != 0xFFFF {
                let packed = Int(slot.rallyPointPacked)
                let rx = packed & 0x3F
                let ry = (packed >> 6) & 0x3F
                Log.info(
                    "rally-fire yard=\(yardIndex) unit=\(unitIdx) tile=(\(rx),\(ry))",
                    tracer: .label("rally")
                )
                Units.orderMove(
                    poolIndex: unitIdx, tileX: rx, tileY: ry, units: &unitPool
                )
            }

            var updated = slot
            updated.state = StructureState.idle.rawValue
            updated.objectType = 0xFFFF
            updated.countDown = 0
            pool[yardIndex] = updated
            return unitIdx
        }

        /// Rally point setter. Writes `rallyPointPacked` on the target
        /// yard if it's a factory (types 3, 4, 5, 7, 10) and the tile
        /// is on-map. Passing `tile == nil` clears the rally (sentinel
        /// `0xFFFF`). Non-factory yards are rejected so the caller
        /// doesn't need to validate the yard kind.
        ///
        /// This feature does not exist in OpenDUNE. `Structure_BuildObject`
        /// spawns units at `Structure_FindFreePosition` with no player
        /// input. We layer a rally tile on top of our sim and feed it
        /// through `Units.orderMove` at spawn time.
        @discardableResult
        public static func setRallyPoint(
            yardIndex: Int,
            tile: (x: Int, y: Int)?,
            pool: inout StructurePool
        ) -> Bool {
            guard yardIndex >= 0, yardIndex < StructurePool.capacitySoft else { return false }
            let slot = pool[yardIndex]
            guard slot.isUsed, slot.isAllocated else { return false }
            switch slot.type {
            case 3, 4, 5, 7, 10: break
            default: return false
            }
            var updated = slot
            let before = slot.rallyPointPacked
            if let tile {
                guard (0..<64).contains(tile.x), (0..<64).contains(tile.y) else { return false }
                updated.rallyPointPacked = UInt16(tile.y * 64 + tile.x)
            } else {
                updated.rallyPointPacked = 0xFFFF
            }
            pool[yardIndex] = updated
            Log.info(
                "rally-set yard=\(yardIndex) type=\(slot.type) \(String(format: "0x%04X", before))→\(String(format: "0x%04X", updated.rallyPointPacked))\(tile.map { " tile=(\($0.x),\($0.y))" } ?? " CLEARED")",
                tracer: .label("rally")
            )
            return true
        }

        /// Port of OpenDUNE's `GUI_Widget_SelectStructure` click handler
        /// narrowed to "yard that should surface a buildable sidebar":
        /// player-owned CONSTRUCTION_YARD or one of the 5 factories.
        /// Walks `findArray`, returns the first slot whose footprint
        /// covers `(tileX, tileY)`. STARPORT is NOT selectable in this
        /// slice — its buildable path (`g_starportAvailable`) is
        /// deferred. REFINERY / PALACE / TURRET / etc. also excluded.
        public static func selectableYardAt(
            tileX: Int, tileY: Int,
            pool: StructurePool,
            playerHouseID: UInt8
        ) -> Int? {
            for idx in pool.findArray {
                let slot = pool[idx]
                guard slot.isUsed, slot.isAllocated else { continue }
                guard slot.houseID == playerHouseID else { continue }
                switch slot.type {
                case 3, 4, 5, 7, 8, 10: break
                default: continue
                }
                let ax = Int(slot.positionX) / 256
                let ay = Int(slot.positionY) / 256
                let footprint = footprintTiles(type: slot.type, anchorX: ax, anchorY: ay)
                for (fx, fy) in footprint where fx == tileX && fy == tileY {
                    return idx
                }
            }
            return nil
        }

        /// Port of the `countDown` decrement from OpenDUNE's
        /// `GameLoop_Structure`. For every BUSY yard in the pool's
        /// `findArray`: if the owning house can pay `costPerTick`
        /// (slice 6b: CY path only), deduct + advance countdown by
        /// `defaultBuildSpeed`; when `countDown` hits zero, flip
        /// `state` to `READY`. If the house can't pay, the yard
        /// stays BUSY without advancing (paused).
        ///
        /// IDLE / JUSTBUILT / READY slots are untouched.
        ///
        /// Factory drain (HV / LV / HIGH_TECH / WOR / BARRACKS) is
        /// deferred to slice 6c — requires `UnitInfo.buildCredits`.
        /// For now factory yards drain 0 credits and always advance.
        public static func tickConstruction(
            pool: inout StructurePool,
            houses: inout HousePool
        ) {
            let step = defaultBuildSpeed
            for idx in pool.findArray {
                let slot = pool[idx]
                guard slot.isUsed, slot.isAllocated else { continue }
                guard slot.state == StructureState.busy.rawValue else { continue }

                // Credit drain — dispatch by yard kind. Slice 6b handles
                // CY via StructureInfo; slice 6c extends to factories
                // via UnitInfo. Skip when objectType is unset
                // (synthetic-test sentinel).
                var canAdvance = true
                if let (buildCredits, buildTime) = producedCost(slot: slot),
                   buildTime > 0
                {
                    let costPerTick = UInt16(max(1, Int(buildCredits) / Int(buildTime)))
                    let houseIdx = Int(slot.houseID)
                    if houseIdx >= 0, houseIdx < HousePool.capacity,
                       houses.slots[houseIdx].isUsed
                    {
                        var h = houses[houseIdx]
                        if h.credits >= costPerTick {
                            h.credits &-= costPerTick
                            houses[houseIdx] = h
                        } else {
                            // House can't pay — pause for this tick.
                            canAdvance = false
                        }
                    }
                    // No house allocated → treat as free (keep advancing).
                }

                guard canAdvance else { continue }

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

        /// Resolves `(buildCredits, buildTime)` for the object a
        /// yard is currently producing. CY yards look up via
        /// `StructureInfo` (produced structure type); factory yards
        /// look up via `UnitInfo`. Returns `nil` for `objectType ==
        /// 0xFFFF`, non-production yards, or unknown types — which
        /// the drain/refund paths treat as "no cost tracking" (used
        /// by synthetic tests and mid-state migrations).
        private static func producedCost(
            slot: StructureSlot
        ) -> (buildCredits: UInt16, buildTime: UInt16)? {
            guard slot.objectType != 0xFFFF else { return nil }
            let objectType = UInt8(truncatingIfNeeded: slot.objectType)
            if slot.type == 8 /* CYARD */ {
                guard let info = StructureInfo.lookup(objectType) else { return nil }
                return (info.buildCredits, info.buildTime)
            }
            // Factory yards (3/4/5/7/10) — use UnitInfo.
            switch slot.type {
            case 3, 4, 5, 7, 10: break
            default: return nil
            }
            guard let info = UnitInfo.lookup(objectType) else { return nil }
            return (info.buildCredits, info.buildTime)
        }

        /// Slice 2 of spice income — dock a harvester into a refinery.
        /// Ports the allied-unit branch of OpenDUNE's `Unit_EnterStructure`
        /// (`src/unit.c:2177..2225`) as a pure-sim function; callers
        /// decide when to call it (arrival detection is a later slice).
        ///
        /// Steps — each logged via the `dock` tracer so traces tell the
        /// full story:
        /// 1. Validate: indices in range, types match (REFINERY = 12,
        ///    HARVESTER = 16), both allocated, same house.
        /// 2. Chain-link: harvester's `linkedID` captures the previous
        ///    refinery head (`0xFF` when first in queue); refinery's
        ///    `linkedID` becomes the new harvester's pool index.
        /// 3. Hide the harvester by setting `inTransport = true`. This
        ///    is a minor semantic overload — OpenDUNE has both
        ///    `flags.isNotOnMap` (physical presence) and `inTransport`
        ///    (carries ore). Our scene uses `inTransport` as the sole
        ///    "hidden during dock" signal; `RefineSpice` clears it on
        ///    unload-complete, at which point `undockHarvester` puts
        ///    the harvester back on the map.
        /// 4. Flip refinery state to READY (REFINERY has
        ///    `busyStateIsIncoming = true`, so dock → READY not BUSY).
        ///
        /// Returns `true` on success, `false` on rejection. Pool state
        /// is untouched on failure.
        @discardableResult
        public static func dockHarvester(
            refineryIndex: Int,
            harvesterIndex: Int,
            structures: inout StructurePool,
            units: inout UnitPool
        ) -> Bool {
            guard refineryIndex >= 0, refineryIndex < StructurePool.capacitySoft else { return false }
            guard harvesterIndex >= 0, harvesterIndex < UnitPool.capacity else { return false }
            let refinery = structures[refineryIndex]
            let harvester = units[harvesterIndex]
            guard refinery.isUsed, refinery.isAllocated, refinery.type == 12 /* REFINERY */ else { return false }
            guard harvester.isUsed, harvester.isAllocated, harvester.type == 16 /* HARVESTER */ else { return false }
            guard refinery.houseID == harvester.houseID else { return false }

            let priorHead = refinery.linkedID
            let priorState = refinery.state

            var u = harvester
            u.linkedID = priorHead
            u.inTransport = true
            units[harvesterIndex] = u
            Log.info(
                "dock step1 harvester=\(harvesterIndex) linkedID=\(priorHead)→(chain-captured) inTransport=true amount=\(u.amount)",
                tracer: .label("dock")
            )

            var r = refinery
            r.linkedID = UInt8(truncatingIfNeeded: harvesterIndex)
            r.state = StructureState.ready.rawValue
            structures[refineryIndex] = r
            Log.info(
                "dock step2 refinery=\(refineryIndex) linkedID=\(priorHead)→\(r.linkedID) state=\(priorState)→READY(\(r.state))",
                tracer: .label("dock")
            )
            return true
        }

        /// Slice 2 of spice income — undock the refinery's head
        /// harvester and place it at `exitTile`. Ports
        /// `Script_Structure_FindAndLeaveUnit`'s unlink dance
        /// (`src/script/structure.c:273..283`).
        ///
        /// Steps (all logged via `dock`):
        /// 1. Refinery must have a linked harvester
        ///    (`linkedID != 0xFF`). Else return nil.
        /// 2. Unlink: refinery.linkedID becomes harvester.linkedID
        ///    (next in chain or `0xFF`); harvester.linkedID becomes
        ///    `0xFF`.
        /// 3. Position the harvester at `exitTile` centred
        ///    (`tile*256+128`); clear `inTransport`.
        /// 4. When refinery's chain is empty after unlink, flip state
        ///    back to IDLE (`if (s->o.linkedID == 0xFF) Structure_SetState(s, STRUCTURE_STATE_IDLE)`).
        ///
        /// Returns the undocked harvester's pool index, or `nil` when
        /// the refinery has no linked unit or validation fails. Does
        /// NOT set `actionID` — callers decide whether to send the
        /// harvester back to spice or issue a fresh move; that keeps
        /// this helper reusable for any post-unload behaviour.
        @discardableResult
        public static func undockHarvester(
            refineryIndex: Int,
            exitTile: (x: Int, y: Int),
            structures: inout StructurePool,
            units: inout UnitPool
        ) -> Int? {
            guard refineryIndex >= 0, refineryIndex < StructurePool.capacitySoft else { return nil }
            guard (0..<64).contains(exitTile.x), (0..<64).contains(exitTile.y) else { return nil }
            let refinery = structures[refineryIndex]
            guard refinery.isUsed, refinery.isAllocated, refinery.type == 12 else { return nil }
            guard refinery.linkedID != 0xFF else { return nil }
            let harvesterIdx = Int(refinery.linkedID)
            guard harvesterIdx < UnitPool.capacity else { return nil }
            let harvester = units[harvesterIdx]
            guard harvester.isUsed, harvester.isAllocated, harvester.type == 16 else { return nil }

            let nextHead = harvester.linkedID

            var r = refinery
            let priorState = r.state
            r.linkedID = nextHead
            if r.linkedID == 0xFF {
                r.state = StructureState.idle.rawValue
            }
            structures[refineryIndex] = r
            Log.info(
                "undock step1 refinery=\(refineryIndex) linkedID=\(harvesterIdx)→\(nextHead) state=\(priorState)→\(r.state)",
                tracer: .label("dock")
            )

            var u = harvester
            u.linkedID = 0xFF
            u.inTransport = false
            u.positionX = UInt16(clamping: exitTile.x * 256 + 128)
            u.positionY = UInt16(clamping: exitTile.y * 256 + 128)
            units[harvesterIdx] = u
            Log.info(
                "undock step2 harvester=\(harvesterIdx) linkedID=\(nextHead)→0xFF inTransport=false tile=(\(exitTile.x),\(exitTile.y))",
                tracer: .label("dock")
            )
            return harvesterIdx
        }

        /// One "refine tick" for a docked harvester at a refinery.
        /// Ports the per-step math in OpenDUNE's `Script_Structure_RefineSpice`
        /// (`src/script/structure.c:105..153`) as a pure function: drains
        /// `harvesterStep` ore from the harvester's `amount`, credits the
        /// owning house `creditsStep × harvesterStep`, returns the credits
        /// gained this call.
        ///
        /// First slice of the harvester / spice income bridge — no script
        /// wiring, no dock/undock AI, no linked-ID management. Caller
        /// passes both pool indices explicitly. Full design in
        /// `Documentation/Algorithms/HarvesterSpiceDeposit.md`.
        ///
        /// `harvesterStep` is scaled by the refinery's HP ratio: a full-HP
        /// refinery drains 3/tick, a half-HP refinery drains 1/tick, a
        /// below-33% HP refinery drains 0 until repaired — `h * 256 / hMax * 3 / 256`
        /// in integer arithmetic.
        ///
        /// `creditsStep` is a flat 7 for player-owned harvesters. Enemy
        /// harvesters get an optional −1..+2 jitter drawn from
        /// `enemyJitterByte() % 4 - 1`. Pass `nil` to disable jitter
        /// entirely (useful for mission-1 scope + deterministic tests).
        ///
        /// Returns 0 and mutates nothing when the pair fails validation
        /// (wrong types, cross-house, unallocated, out of range).
        /// Returns 0 and clears `inTransport` when the harvester's
        /// amount already reads zero — that branch mirrors the C
        /// "unload complete" path.
        ///
        /// Credits saturate at `UInt16.max` rather than wrapping.
        @discardableResult
        public static func refineSpiceStep(
            refineryIndex: Int,
            harvesterIndex: Int,
            structures: StructurePool,
            units: inout UnitPool,
            houses: inout HousePool,
            playerHouseID: UInt8,
            enemyJitterByte: (() -> UInt8)? = nil
        ) -> UInt16 {
            guard refineryIndex >= 0, refineryIndex < StructurePool.capacitySoft else { return 0 }
            guard harvesterIndex >= 0, harvesterIndex < UnitPool.capacity else { return 0 }
            let refinery = structures[refineryIndex]
            let harvester = units[harvesterIndex]
            guard refinery.isUsed, refinery.isAllocated, refinery.type == 12 /* REFINERY */ else { return 0 }
            guard harvester.isUsed, harvester.isAllocated, harvester.type == 16 /* HARVESTER */ else { return 0 }
            guard refinery.houseID == harvester.houseID else { return 0 }
            let houseIdx = Int(harvester.houseID)
            guard houseIdx >= 0, houseIdx < HousePool.capacity,
                  houses.slots[houseIdx].isUsed else { return 0 }

            if harvester.amount == 0 {
                var u = harvester
                let wasInTransport = u.inTransport
                u.inTransport = false
                units[harvesterIndex] = u
                if wasInTransport {
                    Log.info(
                        "refine r\(refineryIndex) h\(harvesterIndex) amount=0 UNLOAD_COMPLETE (inTransport cleared)",
                        tracer: .label("spice")
                    )
                }
                return 0
            }

            let maxStepByHP: Int
            if let info = StructureInfo.lookup(refinery.type), info.hitpoints > 0 {
                maxStepByHP = Int(refinery.hitpoints) * 256 / Int(info.hitpoints) * 3 / 256
            } else {
                maxStepByHP = 0
            }
            let harvesterStep = min(UInt16(max(0, maxStepByHP)), UInt16(harvester.amount))
            if harvesterStep == 0 { return 0 }

            var creditsStep = 7
            if harvester.houseID != playerHouseID, let jitter = enemyJitterByte {
                creditsStep += Int(jitter() % 4) - 1
                creditsStep = max(0, creditsStep)
            }
            let gained = UInt16(clamping: creditsStep * Int(harvesterStep))

            var h = houses[houseIdx]
            let creditsBefore = h.credits
            h.credits = UInt16(clamping: Int(h.credits) + Int(gained))
            houses[houseIdx] = h

            var u = harvester
            let amountBefore = u.amount
            u.amount = UInt8(clamping: Int(u.amount) - Int(harvesterStep))
            if u.amount == 0 { u.inTransport = false }
            units[harvesterIndex] = u

            Log.info(
                "refine r\(refineryIndex)(hp=\(refinery.hitpoints)) h\(harvesterIndex)(house=\(harvester.houseID) amt=\(amountBefore)→\(u.amount)) step=\(harvesterStep) rate=\(creditsStep) +\(gained) credits=\(creditsBefore)→\(h.credits)\(u.amount == 0 ? " UNLOAD_COMPLETE" : "")",
                tracer: .label("spice")
            )
            return gained
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
