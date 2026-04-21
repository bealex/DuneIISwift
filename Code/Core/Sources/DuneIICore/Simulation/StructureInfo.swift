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

        public static let table: [StructureInfo] = [
            // 0 SLAB_1x1
            StructureInfo(hitpoints: 20, buildCredits: 5,   fogUncoverRadius: 1, layout: .s1x1,
                          priorityBuild: 0, priorityTarget: 5),
            // 1 SLAB_2x2
            StructureInfo(hitpoints: 20, buildCredits: 20,  fogUncoverRadius: 1, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 10),
            // 2 PALACE
            StructureInfo(hitpoints: 1000, buildCredits: 999, fogUncoverRadius: 5, layout: .s3x3,
                          priorityBuild: 0, priorityTarget: 400),
            // 3 LIGHT_VEHICLE (Light Fctry)
            StructureInfo(hitpoints: 350, buildCredits: 400, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 200),
            // 4 HEAVY_VEHICLE (Heavy Fctry)
            StructureInfo(hitpoints: 200, buildCredits: 600, fogUncoverRadius: 3, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 600),
            // 5 HIGH_TECH (Hi-Tech)
            StructureInfo(hitpoints: 400, buildCredits: 500, fogUncoverRadius: 3, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 200),
            // 6 HOUSE_OF_IX
            StructureInfo(hitpoints: 400, buildCredits: 500, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 100),
            // 7 WOR_TROOPER (WOR)
            StructureInfo(hitpoints: 400, buildCredits: 400, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 175),
            // 8 CONSTRUCTION_YARD
            StructureInfo(hitpoints: 400, buildCredits: 400, fogUncoverRadius: 3, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 300),
            // 9 WINDTRAP
            StructureInfo(hitpoints: 200, buildCredits: 300, fogUncoverRadius: 2, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 300),
            // 10 BARRACKS
            StructureInfo(hitpoints: 300, buildCredits: 300, fogUncoverRadius: 2, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 100),
            // 11 STARPORT
            StructureInfo(hitpoints: 500, buildCredits: 500, fogUncoverRadius: 6, layout: .s3x3,
                          priorityBuild: 0, priorityTarget: 250),
            // 12 REFINERY
            StructureInfo(hitpoints: 450, buildCredits: 400, fogUncoverRadius: 4, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 300),
            // 13 REPAIR
            StructureInfo(hitpoints: 200, buildCredits: 700, fogUncoverRadius: 3, layout: .s3x2,
                          priorityBuild: 0, priorityTarget: 600),
            // 14 WALL
            StructureInfo(hitpoints: 50,  buildCredits: 50,  fogUncoverRadius: 1, layout: .s1x1,
                          priorityBuild: 0, priorityTarget: 30),
            // 15 TURRET
            StructureInfo(hitpoints: 200, buildCredits: 125, fogUncoverRadius: 2, layout: .s1x1,
                          priorityBuild: 75, priorityTarget: 150),
            // 16 ROCKET_TURRET (R-Turret)
            StructureInfo(hitpoints: 200, buildCredits: 250, fogUncoverRadius: 5, layout: .s1x1,
                          priorityBuild: 100, priorityTarget: 75),
            // 17 SILO
            StructureInfo(hitpoints: 150, buildCredits: 150, fogUncoverRadius: 2, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 150),
            // 18 OUTPOST
            StructureInfo(hitpoints: 500, buildCredits: 400, fogUncoverRadius: 10, layout: .s2x2,
                          priorityBuild: 0, priorityTarget: 275)
        ]

        public static func lookup(_ type: UInt8) -> StructureInfo? {
            let i = Int(type)
            guard i >= 0, i < table.count else { return nil }
            return table[i]
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
