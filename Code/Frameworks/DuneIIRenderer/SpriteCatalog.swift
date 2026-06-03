import Foundation

/// Maps the flat frame lists of the unit SHP files into logical per-unit sprite groups, labeled
/// directional (facing-selected, not time-animated) or animation (cycled over time). This data is NOT
/// in the SHP files — it is transcribed from OpenDUNE's `g_table_unitInfo` (`src/table/unitinfo.c`),
/// the `DisplayMode` enum (`src/unit.h`), the orientation tables (`src/gui/viewport.c`), and the
/// global sprite load order in `Sprites_Init` (`src/sprites.c:485`):
///   UNITS2.SHP base 111, UNITS1.SHP base 151, UNITS.SHP base 238.
/// `firstFrame` here is the LOCAL frame index within the named SHP (global sprite ID − base offset).
///
/// Frame counts per displayMode (verified against the renderer): ground UNIT 5, air UNIT 3,
/// INFANTRY_3 9, INFANTRY_4 12, ORNITHOPTER 9, ROCKET 5, turret 5, single 1. Label = animation iff
/// displayMode ∈ {infantry, ornithopter} or animationSpeed ≠ 0.
///
/// Note: this is rendering metadata; when `DuneIIWorld` ports the full `unitInfo` it should supersede
/// and validate this table. Several units intentionally share body/turret sprites in the original.
public enum SpriteCatalog {
    public enum GroupKind: Hashable, Sendable {
        case directional
        case animation
    }

    public struct Group: Hashable, Sendable {
        public let unit: String
        public let part: String  // "body" or "turret"
        public let shp: String  // e.g. "UNITS.SHP"
        public let firstFrame: Int  // local frame index within `shp`
        public let frameCount: Int
        public let kind: GroupKind

        public var label: String { part == "body" ? unit : "\(unit) (\(part))" }
    }

    /// All known unit sprite groups, keyed by SHP file via `groups(inShp:)`.
    public static let unitGroups: [Group] = [
        // UNITS.SHP (base 238)
        .init(unit: "Carryall", part: "body", shp: "UNITS.SHP", firstFrame: 45, frameCount: 3, kind: .directional),
        .init(unit: "Ornithopter", part: "body", shp: "UNITS.SHP", firstFrame: 51, frameCount: 9, kind: .animation),
        .init(unit: "Frigate", part: "body", shp: "UNITS.SHP", firstFrame: 60, frameCount: 3, kind: .directional),
        .init(unit: "Quad", part: "body", shp: "UNITS.SHP", firstFrame: 0, frameCount: 5, kind: .directional),
        .init(unit: "Trike", part: "body", shp: "UNITS.SHP", firstFrame: 5, frameCount: 5, kind: .directional),
        .init(unit: "Raider Trike", part: "body", shp: "UNITS.SHP", firstFrame: 5, frameCount: 5, kind: .directional),
        .init(unit: "Harvester", part: "body", shp: "UNITS.SHP", firstFrame: 10, frameCount: 5, kind: .directional),
        .init(unit: "MCV", part: "body", shp: "UNITS.SHP", firstFrame: 15, frameCount: 5, kind: .directional),
        .init(unit: "Saboteur", part: "body", shp: "UNITS.SHP", firstFrame: 63, frameCount: 9, kind: .animation),
        .init(unit: "Soldier", part: "body", shp: "UNITS.SHP", firstFrame: 73, frameCount: 9, kind: .animation),
        .init(unit: "Trooper", part: "body", shp: "UNITS.SHP", firstFrame: 82, frameCount: 9, kind: .animation),
        .init(unit: "Infantry", part: "body", shp: "UNITS.SHP", firstFrame: 91, frameCount: 12, kind: .animation),
        .init(unit: "Troopers", part: "body", shp: "UNITS.SHP", firstFrame: 103, frameCount: 12, kind: .animation),
        .init(unit: "Rocket", part: "body", shp: "UNITS.SHP", firstFrame: 20, frameCount: 5, kind: .animation),
        .init(unit: "MiniRocket", part: "body", shp: "UNITS.SHP", firstFrame: 30, frameCount: 5, kind: .animation),
        .init(unit: "Death Hand", part: "body", shp: "UNITS.SHP", firstFrame: 40, frameCount: 5, kind: .directional),
        // UNITS2.SHP (base 111) — combat vehicles; several share the body sprite, turrets differ.
        .init(unit: "Combat Tank", part: "body", shp: "UNITS2.SHP", firstFrame: 0, frameCount: 5, kind: .directional),
        .init(unit: "Combat Tank", part: "turret", shp: "UNITS2.SHP", firstFrame: 5, frameCount: 5, kind: .directional),
        .init(unit: "Siege Tank", part: "body", shp: "UNITS2.SHP", firstFrame: 10, frameCount: 5, kind: .directional),
        .init(unit: "Siege Tank", part: "turret", shp: "UNITS2.SHP", firstFrame: 15, frameCount: 5, kind: .directional),
        .init(unit: "Devastator", part: "body", shp: "UNITS2.SHP", firstFrame: 20, frameCount: 5, kind: .directional),
        .init(unit: "Devastator", part: "turret", shp: "UNITS2.SHP", firstFrame: 25, frameCount: 5, kind: .directional),
        .init(unit: "Sonic Tank", part: "turret", shp: "UNITS2.SHP", firstFrame: 30, frameCount: 5, kind: .directional),
        .init(unit: "Launcher", part: "turret", shp: "UNITS2.SHP", firstFrame: 35, frameCount: 5, kind: .directional),
        // UNITS1.SHP (base 151)
        .init(unit: "Sonic Blast", part: "body", shp: "UNITS1.SHP", firstFrame: 9, frameCount: 1, kind: .animation),
        .init(unit: "Sandworm", part: "body", shp: "UNITS1.SHP", firstFrame: 10, frameCount: 1, kind: .animation),
        .init(unit: "Bullet", part: "body", shp: "UNITS1.SHP", firstFrame: 23, frameCount: 1, kind: .directional),
    ]

    public static func groups(inShp shp: String) -> [Group] {
        unitGroups.filter { $0.shp.caseInsensitiveCompare(shp) == .orderedSame }
    }

    /// SHP file names that have a logical grouping.
    public static let groupedShpFiles: Set<String> = Set(unitGroups.map(\.shp))
}
