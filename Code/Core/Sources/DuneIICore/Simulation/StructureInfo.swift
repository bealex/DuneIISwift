import Foundation

extension Simulation {
    /// Multi-tile footprint enum (`src/structure.h` `StructureLayout`).
    public enum StructureLayout: UInt8, Sendable {
        case s1x1 = 0
        case s2x1 = 1
        case s1x2 = 2
        case s2x2 = 3
        case s2x3 = 4
        case s3x2 = 5
        case s3x3 = 6

        public var dimensions: (width: Int, height: Int) {
            switch self {
            case .s1x1: return (1, 1)
            case .s2x1: return (2, 1)
            case .s1x2: return (1, 2)
            case .s2x2: return (2, 2)
            case .s2x3: return (2, 3)
            case .s3x2: return (3, 2)
            case .s3x3: return (3, 3)
            }
        }

        /// Port of `g_table_structure_layoutEdgeTiles[layout][8]`
        /// (`src/table/structureinfo.c:1261`). For a given
        /// orientation8 index in 0..7, returns the packed-tile offset
        /// from the structure's origin tile to the edge tile nearest
        /// an attacker approaching from that direction. Used by
        /// `Object_GetDistanceToEncoded` to compute fire-range
        /// distance from the structure's perimeter rather than its
        /// centre — without this a SOLDIER firing at a 2x2 CYARD from
        /// just outside its south edge reads distance ~555 (centre)
        /// vs the correct ~235 (south edge), and the fire gate
        /// rejects the shot.
        public var edgeTileOffsets: [Int16] {
            switch self {
            case .s1x1: return [0, 0,    0,     0,     0,     0,     0, 0]
            case .s2x1: return [0, 1,    1,     1,     1,     0,     0, 0]
            case .s1x2: return [0, 0,    0,  64,    64,    64,     0, 0]
            case .s2x2: return [0, 1,    1,  65,    65,    64,    64, 0]
            case .s2x3: return [0, 1,   65, 129,   129,   128,    64, 0]
            case .s3x2: return [1, 2,    2,  66,    65,    64,     0, 0]
            case .s3x3: return [1, 2,   66, 130,   129,   128,    64, 0]
            }
        }

        /// Port of `g_table_structure_layoutTileDiff` (pixel offsets in
        /// the tile32 coordinate system). Added to the structure's
        /// stored top-left position to get the layout-adjusted tile
        /// centre — what OpenDUNE's `Tools_Index_GetTile` returns for
        /// a structure encoded-index. Used by Fire's orientation-diff
        /// gate + anywhere else that needs the "target tile" of a
        /// structure rather than its raw anchor.
        public var tileDiff: (x: UInt16, y: UInt16) {
            switch self {
            case .s1x1: return (0x80, 0x80)
            case .s2x1: return (0x100, 0x80)
            case .s1x2: return (0x80, 0x100)
            case .s2x2: return (0x100, 0x100)
            case .s2x3: return (0x100, 0x180)
            case .s3x2: return (0x280, 0x100)
            case .s3x3: return (0x180, 0x180)
            }
        }

        /// `(dx, dy)` tile offsets from the anchor covered by this
        /// layout. Port of OpenDUNE's `g_table_structure_layoutTiles`
        /// (`src/table/structureinfo.c`), decomposed from packed-tile
        /// form (+1 east, +64 south) into explicit coordinates.
        public var footprintOffsets: [(x: Int, y: Int)] {
            let (w, h) = dimensions
            var result: [(x: Int, y: Int)] = []
            result.reserveCapacity(w * h)
            for dy in 0..<h {
                for dx in 0..<w {
                    result.append((x: dx, y: dy))
                }
            }
            return result
        }

        /// `(dx, dy)` offsets for the ring of tiles surrounding a
        /// structure of this layout — used by the adjacency gate in
        /// `Structure_IsValidBuildLocation`. Port of OpenDUNE's
        /// `g_table_structure_layoutTilesAround`; trailing `0`
        /// terminators in the C source are dropped (Swift emits only
        /// the valid entries).
        ///
        /// Clockwise walk matching OpenDUNE byte-for-byte:
        /// N-edge (including NE corner) → E-edge → S-edge (including SE
        /// and SW corners) → W-edge → NW corner. Total entries are
        /// `2*(width + height) + 4` (8 for s1x1 up to 16 for s3x3).
        public var adjacentOffsets: [(x: Int, y: Int)] {
            let (w, h) = dimensions
            var result: [(x: Int, y: Int)] = []
            result.reserveCapacity(2 * (w + h) + 4)
            // N edge including NE corner: (0..w, -1)
            for dx in 0...w { result.append((x: dx, y: -1)) }
            // E edge below NE corner: (w, 0..h-1)
            for dy in 0..<h { result.append((x: w, y: dy)) }
            // S edge including SE and SW corners: (w..-1, h)
            for dx in stride(from: w, through: -1, by: -1) {
                result.append((x: dx, y: h))
            }
            // W edge below SW corner: (-1, h-1..0)
            for dy in stride(from: h - 1, through: 0, by: -1) {
                result.append((x: -1, y: dy))
            }
            // NW corner closes the ring.
            result.append((x: -1, y: -1))
            return result
        }
    }

    /// Per-structure-type stats, trimmed to what our wired host functions
    /// + P5 scenario visuals need. Source: `src/table/structureinfo.c`.
    public struct StructureInfo: Sendable, Equatable {
        public let hitpoints: UInt16
        public let buildCredits: UInt16
        public let fogUncoverRadius: UInt8
        public let layout: StructureLayout
        /// `ObjectInfo.priorityBuild`. Summed with `priorityTarget` in
        /// target-acquisition math (`Unit_GetTargetStructurePriority`).
        public let priorityBuild: UInt16
        /// `ObjectInfo.priorityTarget`. "How badly someone wants to shoot
        /// this structure". Read during `FindBestTarget`.
        public let priorityTarget: UInt16
        /// `ObjectInfo.availableCampaign`. 1-indexed mission at which
        /// this type unlocks (`99` = never). The buildable-set gate is
        /// `campaignID >= availableCampaign - 1`. Unsigned-wrap matters:
        /// ROCKET_TURRET has `availableCampaign == 0`, so `&- 1 ==
        /// 0xFFFF` and the gate always fails through this field alone.
        public let availableCampaign: UInt16
        /// `ObjectInfo.availableHouse`. `1 << houseID` bitmask. `flagAll`
        /// = every house. BARRACKS excludes Harkonnen, WOR excludes
        /// Atreides. See `Simulation.House.flagAll / flagBarracksHouses
        /// / flagWorHouses`.
        public let availableHouse: UInt8
        /// `ObjectInfo.structuresRequired`. Bitmask of structure type
        /// IDs that must already be in the owner's `structuresBuilt`
        /// before a construction yard may queue this type.
        /// `FLAG_STRUCTURE_NONE` = 0, `FLAG_STRUCTURE_NEVER` = `0x80000000`
        /// (used for CONSTRUCTION_YARD).
        public let structuresRequired: UInt32
        /// `ObjectInfo.upgradeLevelRequired`. Minimum `upgradeLevel` on
        /// the construction yard. AI yards skip this gate (parity with
        /// `Structure_GetBuildable`).
        public let upgradeLevelRequired: UInt8
        /// `ObjectInfo.sortPriority`. Build-panel row order — lower
        /// comes first. CONSTRUCTION_YARD is 0 (never shown in panel
        /// since you can't build one), so the effective first panel
        /// row is SLAB_1x1 (2). See `buildableTypesByPriority`.
        public let sortPriority: UInt16
        /// `ObjectInfo.flags.notOnConcrete`. True only for
        /// CONSTRUCTION_YARD: the yard can never sit on a concrete
        /// slab (OpenDUNE quirk — the `isValidForStructure2` gate
        /// excludes `LST_CONCRETE_SLAB`). False for every other
        /// structure. Defaulted so the 18 non-CY rows don't need to
        /// spell it out.
        public let notOnConcrete: Bool
        /// `ObjectInfo.buildTime`. Units are "game ticks at standard
        /// buildSpeed = 256" — our `tickConstruction` drains `countDown
        /// = buildTime << 8` at 256 per tick, so the full build takes
        /// `buildTime` ticks (~4 seconds for a WINDTRAP at the
        /// scheduler's 12 Hz cadence).
        public let buildTime: UInt16
        /// `StructureInfo.buildableUnits[8]`. Per-factory list of unit
        /// type IDs producible here; `0xFF` entries are empty slots.
        /// Populated only for LIGHT_VEHICLE (3), HEAVY_VEHICLE (4),
        /// HIGH_TECH (5), WOR_TROOPER (7), BARRACKS (10). Default is
        /// an all-`0xFF` array — non-factory rows inherit it. Slice 5a.
        public let buildableUnits: [UInt8]

        public init(
            hitpoints: UInt16,
            buildCredits: UInt16,
            fogUncoverRadius: UInt8,
            layout: StructureLayout,
            priorityBuild: UInt16,
            priorityTarget: UInt16,
            availableCampaign: UInt16,
            availableHouse: UInt8,
            structuresRequired: UInt32,
            upgradeLevelRequired: UInt8,
            sortPriority: UInt16,
            buildTime: UInt16,
            notOnConcrete: Bool = false,
            buildableUnits: [UInt8] = Array(repeating: 0xFF, count: 8)
        ) {
            self.hitpoints = hitpoints
            self.buildCredits = buildCredits
            self.fogUncoverRadius = fogUncoverRadius
            self.layout = layout
            self.priorityBuild = priorityBuild
            self.priorityTarget = priorityTarget
            self.availableCampaign = availableCampaign
            self.availableHouse = availableHouse
            self.structuresRequired = structuresRequired
            self.upgradeLevelRequired = upgradeLevelRequired
            self.sortPriority = sortPriority
            self.buildTime = buildTime
            self.notOnConcrete = notOnConcrete
            self.buildableUnits = buildableUnits
        }

        /// `FLAG_STRUCTURE_NEVER` sentinel. Used for CONSTRUCTION_YARD:
        /// `(structuresBuilt & required) == required` can never be true
        /// because bit 31 is never set in any house's `structuresBuilt`
        /// (only type IDs 0..18 exist).
        public static let flagStructureNever: UInt32 = 0x80000000

        public static let table: [StructureInfo] = [
            // 0 SLAB_1x1
            StructureInfo(hitpoints: 20, buildCredits: 5,   fogUncoverRadius: 1, layout: .s1x1,
                          priorityBuild: 0, priorityTarget: 5,
                          availableCampaign: 1,  availableHouse: House.flagAll,
                          structuresRequired: 0, upgradeLevelRequired: 0,
                          sortPriority: 2, buildTime: 16),
            // 1 SLAB_2x2
            StructureInfo(hitpoints: 20, buildCredits: 20,  fogUncoverRadius: 1, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 10,
                          availableCampaign: 4,  availableHouse: House.flagAll,
                          structuresRequired: 0, upgradeLevelRequired: 1,
                          sortPriority: 4, buildTime: 16),
            // 2 PALACE
            StructureInfo(hitpoints: 1000, buildCredits: 999, fogUncoverRadius: 5, layout: .s3x3,
                          priorityBuild: 0, priorityTarget: 400,
                          availableCampaign: 8,  availableHouse: House.flagAll,
                          structuresRequired: 1 << 11, upgradeLevelRequired: 0,
                          sortPriority: 5, buildTime: 130),
            // 3 LIGHT_VEHICLE (Light Fctry) — needs REFINERY|WINDTRAP
            StructureInfo(hitpoints: 350, buildCredits: 400, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 200,
                          availableCampaign: 3,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 12) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 14, buildTime: 96,
                          buildableUnits: [13, 15, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            // 4 HEAVY_VEHICLE (Heavy Fctry) — needs OUTPOST|WINDTRAP|LIGHT_VEHICLE
            StructureInfo(hitpoints: 200, buildCredits: 600, fogUncoverRadius: 3, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 600,
                          availableCampaign: 4,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 18) | (1 << 9) | (1 << 3), upgradeLevelRequired: 0,
                          sortPriority: 28, buildTime: 144,
                          buildableUnits: [10, 7, 16, 9, 11, 8, 17, 12]),
            // 5 HIGH_TECH (Hi-Tech) — needs OUTPOST|WINDTRAP|LIGHT_VEHICLE
            StructureInfo(hitpoints: 400, buildCredits: 500, fogUncoverRadius: 3, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 200,
                          availableCampaign: 5,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 18) | (1 << 9) | (1 << 3), upgradeLevelRequired: 0,
                          sortPriority: 30, buildTime: 120,
                          buildableUnits: [0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            // 6 HOUSE_OF_IX — needs REFINERY|STARPORT|WINDTRAP
            StructureInfo(hitpoints: 400, buildCredits: 500, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 100,
                          availableCampaign: 7,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 12) | (1 << 11) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 34, buildTime: 120),
            // 7 WOR_TROOPER (WOR) — needs OUTPOST|BARRACKS|WINDTRAP, no Atreides
            StructureInfo(hitpoints: 400, buildCredits: 400, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 175,
                          availableCampaign: 5,  availableHouse: House.flagWorHouses,
                          structuresRequired: (1 << 18) | (1 << 10) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 20, buildTime: 104,
                          buildableUnits: [5, 3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            // 8 CONSTRUCTION_YARD — FLAG_STRUCTURE_NEVER + availableCampaign=99
            //   + notOnConcrete=true (the only structure with this flag).
            StructureInfo(hitpoints: 400, buildCredits: 400, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 300,
                          availableCampaign: 99, availableHouse: House.flagAll,
                          structuresRequired: flagStructureNever, upgradeLevelRequired: 0,
                          sortPriority: 0, buildTime: 80, notOnConcrete: true),
            // 9 WINDTRAP
            StructureInfo(hitpoints: 200, buildCredits: 300, fogUncoverRadius: 2, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 300,
                          availableCampaign: 1,  availableHouse: House.flagAll,
                          structuresRequired: 0, upgradeLevelRequired: 0,
                          sortPriority: 6, buildTime: 48),
            // 10 BARRACKS — needs OUTPOST|WINDTRAP, no Harkonnen
            StructureInfo(hitpoints: 300, buildCredits: 300, fogUncoverRadius: 2, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 100,
                          availableCampaign: 2,  availableHouse: House.flagBarracksHouses,
                          structuresRequired: (1 << 18) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 18, buildTime: 72,
                          buildableUnits: [4, 2, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            // 11 STARPORT — needs REFINERY|WINDTRAP
            StructureInfo(hitpoints: 500, buildCredits: 500, fogUncoverRadius: 6, layout: .s3x3,
                          priorityBuild: 0, priorityTarget: 250,
                          availableCampaign: 6,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 12) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 32, buildTime: 120),
            // 12 REFINERY — needs WINDTRAP
            StructureInfo(hitpoints: 450, buildCredits: 400, fogUncoverRadius: 4, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 300,
                          availableCampaign: 1,  availableHouse: House.flagAll,
                          structuresRequired: 1 << 9, upgradeLevelRequired: 0,
                          sortPriority: 8, buildTime: 80),
            // 13 REPAIR — needs OUTPOST|WINDTRAP|LIGHT_VEHICLE
            StructureInfo(hitpoints: 200, buildCredits: 700, fogUncoverRadius: 3, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 600,
                          availableCampaign: 5,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 18) | (1 << 9) | (1 << 3), upgradeLevelRequired: 0,
                          sortPriority: 24, buildTime: 80),
            // 14 WALL — needs OUTPOST|WINDTRAP
            StructureInfo(hitpoints: 50,  buildCredits: 50,  fogUncoverRadius: 1, layout: .s1x1,
                          priorityBuild: 0, priorityTarget: 30,
                          availableCampaign: 4,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 18) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 16, buildTime: 40),
            // 15 TURRET — needs OUTPOST|WINDTRAP
            StructureInfo(hitpoints: 200, buildCredits: 125, fogUncoverRadius: 2, layout: .s1x1,
                          priorityBuild: 75, priorityTarget: 150,
                          availableCampaign: 5,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 18) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 22, buildTime: 64),
            // 16 ROCKET_TURRET (R-Turret) — needs OUTPOST|WINDTRAP + upgradeLevel 2
            StructureInfo(hitpoints: 200, buildCredits: 250, fogUncoverRadius: 5, layout: .s1x1,
                          priorityBuild: 100, priorityTarget: 75,
                          availableCampaign: 0,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 18) | (1 << 9), upgradeLevelRequired: 2,
                          sortPriority: 26, buildTime: 96),
            // 17 SILO — needs REFINERY|WINDTRAP
            StructureInfo(hitpoints: 150, buildCredits: 150, fogUncoverRadius: 2, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 150,
                          availableCampaign: 2,  availableHouse: House.flagAll,
                          structuresRequired: (1 << 12) | (1 << 9), upgradeLevelRequired: 0,
                          sortPriority: 12, buildTime: 48),
            // 18 OUTPOST — needs WINDTRAP
            StructureInfo(hitpoints: 500, buildCredits: 400, fogUncoverRadius: 10, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 275,
                          availableCampaign: 2,  availableHouse: House.flagAll,
                          structuresRequired: 1 << 9, upgradeLevelRequired: 0,
                          sortPriority: 10, buildTime: 80)
        ]

        public static func lookup(_ type: UInt8) -> StructureInfo? {
            let i = Int(type)
            guard i >= 0, i < table.count else { return nil }
            return table[i]
        }

        /// Decodes a buildable bitmask (from `Structures.buildableStructuresFromYard`)
        /// into an ordered list of structure type IDs. Order is ascending
        /// type ID. Bits 19..31 are ignored (only IDs 0..18 are valid
        /// structure types). Useful for stable iteration where panel
        /// ordering is irrelevant; panel code should call
        /// `buildableTypesByPriority` instead.
        public static func buildableTypes(from mask: UInt32) -> [UInt8] {
            var result: [UInt8] = []
            for typeID in UInt8(0)..<UInt8(19) where (mask & (UInt32(1) << UInt32(typeID))) != 0 {
                result.append(typeID)
            }
            return result
        }

        /// Same as `buildableTypes(from:)` but sorted ascending by
        /// `sortPriority`. This is the order OpenDUNE's factory window
        /// uses (`src/gui/widget.c`) — e.g. WINDTRAP (6) appears before
        /// REFINERY (8), not SLAB_2x2 (4) before PALACE (5). Stable
        /// for ties (none in the shipped table).
        public static func buildableTypesByPriority(from mask: UInt32) -> [UInt8] {
            let unsorted = buildableTypes(from: mask)
            return unsorted.sorted { a, b in
                let pa = table[Int(a)].sortPriority
                let pb = table[Int(b)].sortPriority
                return pa < pb
            }
        }

        /// OpenDUNE's `iconGroup` field per structure type
        /// (`src/table/structureinfo.c`). Resolves to a
        /// `Formats.IconMap.Group` raw value. Used by the scenario-world
        /// stamp to paint the structure's footprint with its real ICN
        /// tiles instead of leaving the baseline sand / rock showing.
        public static func iconGroupRawValue(for type: UInt8) -> Int? {
            switch type {
            case 0:  return 8   // SLAB_1x1 → concreteSlab
            case 1:  return 8   // SLAB_2x2 → concreteSlab
            case 2:  return 11  // PALACE → housePalace
            case 3:  return 12  // LIGHT_VEHICLE → lightVehicleFactory
            case 4:  return 13  // HEAVY_VEHICLE → heavyVehicleFactory
            case 5:  return 14  // HIGH_TECH → hiTechFactory
            case 6:  return 15  // HOUSE_OF_IX → ixResearch
            case 7:  return 16  // WOR_TROOPER → worTrooperFacility
            case 8:  return 17  // CONSTRUCTION_YARD → constructionYard
            case 9:  return 19  // WINDTRAP → windtrapPower
            case 10: return 18  // BARRACKS → infantryBarracks
            case 11: return 20  // STARPORT → starportFacility
            case 12: return 21  // REFINERY → spiceRefinery
            case 13: return 22  // REPAIR → vehicleRepairCentre
            case 14: return 6   // WALL → walls
            case 15: return 23  // TURRET → baseDefenseTurret
            case 16: return 24  // ROCKET_TURRET → baseRocketTurret
            case 17: return 25  // SILO → spiceStorageSilo
            case 18: return 26  // OUTPOST → radarOutpost
            default: return nil
            }
        }

        /// Pos32 tile offset from a structure's anchor (top-left) to its
        /// "center" used by `Unit_FindBestTargetStructure` for distance
        /// calculations. Port of OpenDUNE's `g_table_structure_layoutTileDiff`
        /// in `src/table/structureinfo.c`. Units are pos32 pixels
        /// (one tile = 256).
        public static func layoutTileDiff(_ layout: StructureLayout) -> (x: UInt16, y: UInt16) {
            switch layout {
            case .s1x1: return (0, 0)
            case .s2x1: return (128, 0)
            case .s1x2: return (0, 128)
            case .s2x2: return (128, 128)
            case .s2x3: return (128, 256)
            case .s3x2: return (256, 128)
            case .s3x3: return (256, 256)
            }
        }
    }
}
