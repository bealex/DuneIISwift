import Foundation
import Memoirs

extension Simulation {
    /// Value-type bridge from a decoded save file into the live world state:
    /// populated `HousePool` / `UnitPool` / `StructurePool` plus a dense
    /// 4096-cell tile grid with the save's sparse overrides layered on top
    /// of a map-seed-generated baseline.
    ///
    /// Contract: `Documentation/Architecture/WorldSnapshot.md`.
    public struct WorldSnapshot: Sendable, Equatable {
        public let houses: HousePool
        public let units: UnitPool
        public let structures: StructurePool
        public let teams: TeamPool
        public let tiles: [Tile]

        public struct Tile: Sendable, Equatable {
            public let groundTileID: UInt16
            public let overlayTileID: UInt16
            public let houseID: UInt8
            public let isUnveiled: Bool
            public let hasUnit: Bool
            public let hasStructure: Bool
            public let hasAnimation: Bool
            public let hasExplosion: Bool
            /// Pool-index-plus-one. `0` = no object, `n` = Unit or Structure
            /// at pool index `n - 1`. See `format-save-map-is-sparse-not-fixed.md`.
            public let objectRef: UInt8

            public init(
                groundTileID: UInt16,
                overlayTileID: UInt16,
                houseID: UInt8,
                isUnveiled: Bool,
                hasUnit: Bool,
                hasStructure: Bool,
                hasAnimation: Bool,
                hasExplosion: Bool,
                objectRef: UInt8
            ) {
                self.groundTileID = groundTileID
                self.overlayTileID = overlayTileID
                self.houseID = houseID
                self.isUnveiled = isUnveiled
                self.hasUnit = hasUnit
                self.hasStructure = hasStructure
                self.hasAnimation = hasAnimation
                self.hasExplosion = hasExplosion
                self.objectRef = objectRef
            }
        }

        public enum LoadError: Error, Equatable, Sendable {
            case duplicateHouseIndex(UInt16)
            case unitIndexOutOfRange(UInt16)
            case duplicateUnitIndex(UInt16)
            case structureIndexOutOfRange(UInt16)
            case duplicateStructureIndex(UInt16)
        }

        /// Convenience: generates a fresh `Map` from the save's `mapSeed`
        /// via `Map.Generator` and uses it as the baseline. Equivalent to
        /// `WorldSnapshot(loading: game, baseline: Map.Generator.generate(seed:resolver:))`.
        /// The resolver has to come from the install (icon-map group table),
        /// so this constructor lives outside the pure-CLI TDD path.
        public init(loading game: Formats.Save.Game, resolver: TileResolver) throws {
            let baseline = Map.Generator.generate(seed: game.info.scenario.mapSeed, resolver: resolver)
            try self.init(loading: game, baseline: baseline)
        }

        /// Builds a fresh snapshot straight from a scenario INI load —
        /// no save file involved. Allocates one pool slot per spawn in the
        /// order the scenario declares them. The baseline map runs through
        /// `Map.Generator` with the scenario seed, same as the save path.
        ///
        /// Reserved structure slots (`79`, `80`, `81`) are never populated
        /// here — scenarios don't place walls or slabs through the
        /// aggregate-slot mechanism; those come in as individual `GEN*`
        /// structure rows that get stamped onto the tile grid by
        /// `ScenarioWorld` instead.
        public init(scenario: Scenario, resolver: TileResolver) throws {
            let baseline = Map.Generator.generate(seed: scenario.mapField.seed, resolver: resolver)

            var houses = HousePool()
            for (house, layout) in scenario.houses {
                let idx = Int(house.typeID)
                guard idx >= 0, idx < HousePool.capacity else { continue }
                if !houses.slots[idx].isUsed {
                    houses.allocate(at: idx)
                }
                // Slice 6a: seed credits + quota from the scenario's
                // HouseLayout. `creditsStorage` stays 0 — scenarios
                // don't specify it; derived at runtime from refinery
                // count.
                var h = houses[idx]
                h.credits = UInt16(clamping: layout.credits)
                h.creditsQuota = UInt16(clamping: layout.quota)
                houses[idx] = h
            }

            Log.info(
                "WorldSnapshot(scenario:) spawning \(scenario.units.count) units, \(scenario.structures.count) structures, seed=\(scenario.mapField.seed)",
                tracer: .label("worldsnapshot")
            )

            var units = UnitPool()
            for spawn in scenario.units {
                // Allocate in the per-type `UnitInfo.indexStart..indexEnd`
                // range — port of OpenDUNE's `Unit_Allocate(UNIT_INDEX_INVALID)`.
                // Sequential `allocate(at:)` starting at 0 clobbered the
                // 12..15 bullet range, so every `createBullet` on an
                // enemy soldier-heavy scenario failed with "pool full".
                let typeID = spawn.unitType.typeID
                let houseID = spawn.house.typeID
                guard let i = units.allocateForType(type: typeID, houseID: houseID)
                else {
                    Log.warning(
                        "WorldSnapshot spawn type=\(typeID) house=\(houseID) pool full — unit dropped",
                        tracer: .label("worldsnapshot")
                    )
                    continue
                }
                var slot = units[i]
                slot.orientationCurrent = Int8(truncatingIfNeeded: spawn.orientation)
                // Seed the action from the scenario INI's 6th field
                // (`Guard`, `Hunt`, `Area Guard`, etc.). Without this
                // every unit would spawn into `ACTION_ATTACK` (action 0)
                // with no target and sit idle — `Script_Unit_IdleAction`
                // is dispatched from `ACTION_GUARD`'s EMC entry point,
                // not from `ACTION_ATTACK`'s.
                slot.actionID = spawn.action.typeID
                let pos = Pos32.centered(at: spawn.position)
                slot.positionX = pos.x
                slot.positionY = pos.y
                // Scenario INI hitpoints is a 0..256 percentage of the
                // unit type's max HP — port of OpenDUNE's
                // `u->hitpoints = ui->o.hitpoints * atoi(split[4]) / 256`
                // (`src/scenario.c`). Mission 1 spawns with HP=256 which
                // means "full" (100%), not literally 256 HP; prior code
                // assigned the raw percent and produced "HP: 256/100"
                // readings in the info panel.
                let hpMax = UnitInfo.lookup(typeID)?.hitpoints ?? 1
                let hpPercent = UInt32(clamping: spawn.hitPoints)
                slot.hitpoints = UInt16(clamping: UInt32(hpMax) &* hpPercent / 256)
                slot.byScenario = true   // every scenario-spawned unit qualifies
                // Units that spawn standing-still need speed = 0 (already
                // the default). MOVEMENT_WINGER types (carryalls, frigate,
                // ornithopters) start at speed 255 in OpenDUNE's `Unit_Create`;
                // preserve that here so they cruise in rather than hover.
                if let info = UnitInfo.lookup(slot.type),
                   info.movementType == .winger {
                    slot.speed = 255
                }
                // Mission-1-style scenarios (no fog) set every spawn
                // visible to every house. Without this bit set the
                // target-priority check in `FindBestTarget` returns 0
                // for every pair — units spawn, can't see each other,
                // and their ATTACK / HUNT scripts have nothing to do.
                // Fog-aware scenarios will need to replace this with
                // per-house radar/uncover logic in a later slice.
                slot.seenByHouses = 0xFF
                units[i] = slot
                Log.debug(
                    "spawn unit[\(i)] type=\(slot.type) house=\(slot.houseID) action=\(slot.actionID) @(\(spawn.position.tile.x),\(spawn.position.tile.y))",
                    tracer: .label("worldsnapshot")
                )
            }

            // Spawn teams from the scenario's `[TEAMS]` section. These
            // drive coordinated enemy waves via TEAM.EMC — without
            // them, enemy units rely on per-unit HUNT / AMBUSH scripts
            // only.
            var teams = TeamPool()
            for (i, spawn) in scenario.teams.enumerated() where i < TeamPool.capacity {
                let action = TeamAction(rawValue: spawn.action.typeID) ?? .normal
                _ = teams.allocate(
                    at: i,
                    houseID: spawn.house.typeID,
                    action: action,
                    movementType: spawn.movementType,
                    minMembers: spawn.minMembers,
                    maxMembers: spawn.maxMembers
                )
                Log.debug(
                    "spawn team[\(i)] house=\(spawn.house.typeID) action=\(spawn.action.rawValue) mt=\(spawn.movementType) min=\(spawn.minMembers) max=\(spawn.maxMembers)",
                    tracer: .label("worldsnapshot")
                )
            }
            if !scenario.teams.isEmpty {
                Log.info(
                    "spawned \(teams.findArray.count) team slots",
                    tracer: .label("worldsnapshot")
                )
            }

            var structures = StructurePool()
            var structureIndex = 0
            for spawn in scenario.structures {
                if spawn.isGenerated { continue }      // slabs/walls don't occupy pool slots
                if structureIndex >= StructurePool.capacitySoft { break }
                structures.allocate(
                    at: structureIndex,
                    type: spawn.structureType.typeID,
                    houseID: spawn.house.typeID
                )
                var s = structures[structureIndex]
                let pos = Pos32.centered(at: spawn.position)
                s.positionX = pos.x
                s.positionY = pos.y
                s.hitpoints = UInt16(clamping: spawn.hitPoints)
                // Max HP always comes from the type table — the scenario
                // INI may spawn a pre-damaged structure, but the repair
                // ceiling is fixed by the type.
                if let info = Simulation.StructureInfo.lookup(spawn.structureType.typeID) {
                    s.hitpointsMax = info.hitpoints
                }
                structures[structureIndex] = s
                structureIndex &+= 1
            }

            // Tiles: same as the save path, but without sparse overrides.
            var tiles = [Tile](); tiles.reserveCapacity(baseline.cells.count)
            for cell in baseline.cells {
                tiles.append(Tile(
                    groundTileID: cell.groundTileID,
                    overlayTileID: cell.overlayTileID,
                    houseID: 0,
                    isUnveiled: false,
                    hasUnit: false,
                    hasStructure: cell.hasStructure,
                    hasAnimation: false,
                    hasExplosion: false,
                    objectRef: 0
                ))
            }

            self.houses = houses
            self.units = units
            self.structures = structures
            self.teams = teams
            self.tiles = tiles
        }

        public init(loading game: Formats.Save.Game, baseline: Map) throws {
            // `Map.init` already asserts `cells.count == 4096`; we trust that here.

            // Houses
            var houses = HousePool()
            for slot in game.houses.slots {
                let idx = Int(slot.index)
                guard idx >= 0, idx < HousePool.capacity, !houses.slots[idx].isUsed else {
                    throw LoadError.duplicateHouseIndex(slot.index)
                }
                houses.allocate(at: idx)
                var h = houses[idx]
                h.starportLinkedID = slot.starportLinkedID
                h.starportTimeLeft = slot.starportTimeLeft
                // Slice 6a: plumb credit state from the save record.
                h.credits = slot.credits
                h.creditsStorage = slot.creditsStorage
                h.creditsQuota = slot.creditsQuota
                houses[idx] = h
            }

            // Units
            var units = UnitPool()
            for slot in game.units.slots {
                let idx = Int(slot.object.index)
                guard idx >= 0, idx < UnitPool.capacity else {
                    throw LoadError.unitIndexOutOfRange(slot.object.index)
                }
                guard !units.slots[idx].isUsed else {
                    throw LoadError.duplicateUnitIndex(slot.object.index)
                }
                units.allocate(at: idx, type: slot.object.type, houseID: slot.object.houseID)
                var u = units[idx]
                u.linkedID = slot.object.linkedID
                if !slot.orientation.isEmpty {
                    u.orientationCurrent = slot.orientation[0].current
                    u.orientationTarget = slot.orientation[0].target
                    u.orientationSpeed = slot.orientation[0].speed
                }
                u.actionID = slot.actionID
                u.amount = slot.amount
                u.targetAttack = slot.targetAttack
                u.targetMove = slot.targetMove
                u.originEncoded = slot.originEncoded
                u.positionX = slot.object.positionX
                u.positionY = slot.object.positionY
                u.hitpoints = slot.object.hitpoints
                u.seenByHouses = slot.object.seenByHouses
                u.speed = slot.speed
                u.speedPerTick = slot.speedPerTick
                u.speedRemainder = slot.speedRemainder
                u.movingSpeed = slot.movingSpeed
                u.currentDestinationX = slot.currentDestinationX
                u.currentDestinationY = slot.currentDestinationY
                u.spriteOffset = slot.spriteOffset
                u.blinkCounter = slot.blinkCounter
                u.inTransport = slot.object.flags.inTransport
                u.byScenario = slot.object.flags.byScenario
                u.fireDelay = slot.fireDelay
                u.fireTwiceFlip = slot.object.flags.fireTwiceFlip
                u.team = slot.team
                if slot.route.count == 14 { u.route = slot.route }
                units[idx] = u
            }
            // Match OpenDUNE's post-load `Unit_Recount` (`src/pool/unit.c:75`
            // via `src/saveload/unit.c:108`) so `findArray` is ordered by
            // pool index, not save-chunk order. Save files can store units
            // in arbitrary order (SAVE007 has u39 mid-chunk); without this,
            // `GameLoop_Unit` would dispatch u39 before u25..u38, shifting
            // the RNG stream position for per-unit DelayRandom / Harvest
            // draws.
            units.recount()

            // Structures
            var structures = StructurePool()
            for slot in game.structures.slots {
                let idx = Int(slot.object.index)
                guard idx >= 0, idx < StructurePool.capacityHard else {
                    throw LoadError.structureIndexOutOfRange(slot.object.index)
                }
                guard !structures.slots[idx].isUsed else {
                    throw LoadError.duplicateStructureIndex(slot.object.index)
                }
                if idx < StructurePool.capacitySoft {
                    structures.allocate(at: idx, type: slot.object.type, houseID: slot.object.houseID)
                    var s = structures[idx]
                    s.linkedID = slot.object.linkedID
                    s.state = slot.state
                    s.countDown = slot.countDown
                    s.positionX = slot.object.positionX
                    s.positionY = slot.object.positionY
                    s.hitpoints = slot.object.hitpoints
                    s.hitpointsMax = slot.hitpointsMax
                    s.upgradeLevel = slot.upgradeLevel
                    s.objectType = slot.objectType
                    s.degrades = slot.object.flags.degrades
                    // Saved as u16 but fits in u8 (rotation 0..7 in vanilla).
                    s.rotationSpriteDiff = UInt8(truncatingIfNeeded: slot.rotationSpriteDiff)
                    structures[idx] = s
                } else {
                    structures.allocateReserved(at: idx, type: slot.object.type)
                }
            }

            // Tiles: baseline → snapshot Tiles, then apply sparse overrides.
            var tiles = [Tile](); tiles.reserveCapacity(baseline.cells.count)
            for cell in baseline.cells {
                tiles.append(Tile(
                    groundTileID: cell.groundTileID,
                    overlayTileID: cell.overlayTileID,
                    houseID: 0,
                    isUnveiled: false,
                    hasUnit: false,
                    hasStructure: cell.hasStructure,
                    hasAnimation: false,
                    hasExplosion: false,
                    objectRef: 0
                ))
            }
            for entry in game.tileMap.entries {
                let idx = Int(entry.cellIndex)
                let t = entry.tile
                tiles[idx] = Tile(
                    groundTileID: t.groundTileID,
                    overlayTileID: UInt16(t.overlayTileID),
                    houseID: t.houseID,
                    isUnveiled: t.isUnveiled,
                    hasUnit: t.hasUnit,
                    hasStructure: t.hasStructure,
                    hasAnimation: t.hasAnimation,
                    hasExplosion: t.hasExplosion,
                    objectRef: t.tileIndex
                )
            }

            self.houses = houses
            self.units = units
            self.structures = structures
            // Save-based snapshots don't carry a TEAM chunk in vanilla
            // saves. Leave the pool empty until we land the save-side
            // team decoder.
            self.teams = TeamPool()
            self.tiles = tiles
        }
    }
}
