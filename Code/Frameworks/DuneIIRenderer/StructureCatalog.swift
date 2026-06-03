import Foundation

/// Tile layout (in 16×16 tiles) of each placeable structure, keyed by its `ICON.MAP` icon group.
/// This is NOT in `ICON.MAP`/`ICON.ICN` — it is transcribed from OpenDUNE's `g_table_structureInfo[].layout`
/// (`src/table/structureinfo.c`) resolved through `g_table_structure_layoutSize` (`structureinfo.c:1294`):
/// each structure's `layout` enum maps to a (width, height) in tiles.
///
/// A structure icon group's tiles (see `IconMap`) are laid out as consecutive build/animation states,
/// each `width * height` tiles in row-major order (`g_table_structure_layoutTiles`, `structureinfo.c:1250`,
/// where map offset `64*r + c` ⇒ grid position `(c, r)`). So the full structure for state `s` is
/// `tileIDs[s*w*h ..< (s+1)*w*h]`, and tile `i` of a state sits at tile-grid `(i % w, i / w)`.
/// `Structure_UpdateMap` (`src/structure.c:1779`) draws the *built* state (index 2) exactly this way.
///
/// Only the structure (Buildings) icon groups 11…26 are covered. The 1×1 turrets (23/24) are included
/// for completeness, but their group tiles are individual facings/states, not a multi-tile shape — a
/// consumer should only assemble when `width * height > 1`. Note: rendering metadata; `DuneIIWorld`'s
/// eventual `structureInfo` port should supersede and validate this table.
public enum StructureCatalog {
    /// Tile dimensions (width, height) of the structure in icon group `iconGroup`, or nil for groups
    /// that are not a single placeable structure (terrain/effects, walls, and the shared concrete slab).
    public static func layout(iconGroup: Int) -> (width: Int, height: Int)? {
        layouts[iconGroup]
    }

    private static let layouts: [Int: (width: Int, height: Int)] = [
        11: (3, 3),  // Palace
        12: (2, 2),  // Light Vehicle Factory
        13: (3, 2),  // Heavy Vehicle Factory
        14: (3, 2),  // Hi-Tech Factory
        15: (2, 2),  // IX Research
        16: (2, 2),  // WOR Trooper Facility
        17: (2, 2),  // Construction Yard
        18: (2, 2),  // Infantry Barracks
        19: (2, 2),  // Windtrap
        20: (3, 3),  // Starport
        21: (3, 2),  // Spice Refinery
        22: (3, 2),  // Repair Centre
        23: (1, 1),  // Gun Turret (each group tile is a facing — not assembled)
        24: (1, 1),  // Rocket Turret (each group tile is a facing — not assembled)
        25: (2, 2),  // Spice Silo
        26: (2, 2),  // Radar Outpost
    ]
}
