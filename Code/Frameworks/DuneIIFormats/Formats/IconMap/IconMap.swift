import Foundation

/// Decoder for `ICON.MAP` — the index file that groups `ICON.ICN` tiles into named icon groups
/// (terrain/effects and structures). Ported from the layout documented in OpenDUNE `src/sprites.h:8`
/// and used by `Sprites_LoadTiles` (`src/sprites.c:263`).
///
/// It is a flat array of little-endian `uint16` indices: entry 0 is the icon-group count; entries
/// `1 ..< count` each point at the first tile ID of a group (an offset into the same array); the entry
/// at the count index is 0 (EOF). Group `i`'s tile IDs run from `values[values[i]]` up to (but not
/// including) `values[values[i+1]]` (or end-of-array when the next offset is 0). Each tile ID indexes
/// `ICON.ICN`'s tiles. See `Documentation/Formats/IconMap.md`.
public struct IconMap {
    public enum DecodeError: Error, Equatable {
        case truncated
    }

    public struct Group: Equatable {
        public let index: Int
        public let name: String
        public let tileIDs: [Int]

        /// Groups 11…26 are structures (Palace … Radar Outpost); 1…10 are terrain/effects.
        public var isBuilding: Bool { index >= 11 }
    }

    private let values: [Int]

    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw DecodeError.truncated }

        var values: [Int] = []
        var offset = 0
        while offset + 2 <= bytes.count {
            values.append(bytes.u16LE(at: offset))
            offset += 2
        }
        self.values = values
    }

    /// The tiles of icon group `index` (1-based), or nil if absent / out of range.
    public func group(_ index: Int) -> Group? {
        guard index >= 1, index < values.count else { return nil }

        let start = values[index]
        guard start > 0, start < values.count else { return nil }   // a 0 offset marks EOF

        let next = (index + 1 < values.count) ? values[index + 1] : 0
        let end = (next > start && next <= values.count) ? next : values.count
        return Group(index: index, name: IconMap.name(index), tileIDs: Array(values[start ..< end]))
    }

    /// All present icon groups, in index order.
    public var groups: [Group] {
        let count = values.first ?? 0
        return (1 ..< max(count, 1)).compactMap { group($0) }
    }

    /// The documented name of an icon group (`ICM_ICONGROUP_*`, `src/sprites.h:19`).
    public static func name(_ index: Int) -> String {
        index >= 0 && index < names.count ? names[index] : "Group \(index)"
    }

    private static let names = [
        "",                       // 0: count
        "Rock Craters",           // 1
        "Sand Craters",           // 2
        "Flying-Machine Crash",   // 3
        "Dead Bodies",            // 4
        "Sand Tracks",            // 5
        "Walls",                  // 6
        "Fog of War",             // 7
        "Concrete Slab",          // 8
        "Landscape",              // 9
        "Spice Bloom",            // 10
        "Palace",                 // 11
        "Light Factory",          // 12
        "Heavy Factory",          // 13
        "Hi-Tech Factory",        // 14
        "IX Research",            // 15
        "WOR Facility",           // 16
        "Construction Yard",      // 17
        "Barracks",               // 18
        "Windtrap",               // 19
        "Starport",               // 20
        "Spice Refinery",         // 21
        "Repair Centre",          // 22
        "Gun Turret",             // 23
        "Rocket Turret",          // 24
        "Spice Silo",             // 25
        "Radar Outpost",          // 26
    ]
}
