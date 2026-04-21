import Foundation

/// Fixed 64×64 tile grid. Each cell holds the terrain + overlay IDs, a
/// spice amount byte, and a fog-of-war bitmask per house. All state is
/// value-type, so a `Map` snapshots into a save file trivially.
public struct Map: Sendable, Equatable {
    public struct Cell: Sendable, Equatable {
        public var groundTileID: UInt16
        public var overlayTileID: UInt16
        public var spiceAmount: UInt8
        public var hasStructure: Bool
        /// Bitmask indexed by `House.allCases` order. Bit set = visible.
        public var visibleToHouses: UInt8

        public init(
            groundTileID: UInt16 = 0,
            overlayTileID: UInt16 = 0,
            spiceAmount: UInt8 = 0,
            hasStructure: Bool = false,
            visibleToHouses: UInt8 = 0
        ) {
            self.groundTileID = groundTileID
            self.overlayTileID = overlayTileID
            self.spiceAmount = spiceAmount
            self.hasStructure = hasStructure
            self.visibleToHouses = visibleToHouses
        }
    }

    public static let width = 64
    public static let height = 64

    public var cells: [Cell]

    public init(cells: [Cell]) {
        precondition(cells.count == Self.width * Self.height)
        self.cells = cells
    }

    public static func empty() -> Map {
        Map(cells: Array(repeating: Cell(), count: width * height))
    }

    public subscript(x: Int, y: Int) -> Cell {
        get { cells[y * Self.width + x] }
        set { cells[y * Self.width + x] = newValue }
    }

    /// Writes scenario-level "initial map features" onto the grid. Spice
    /// fields become `spiceAmount = 1` by default; blooms become a single
    /// ground tile set to the resolver's `bloomTileID`.
    public mutating func applyMapField(_ field: Scenario.MapField, resolver: TileResolver) {
        for packed in field.initialSpiceFields {
            let tile = PackedPosition(raw: packed).tile
            let index = Int(tile.y) * Self.width + Int(tile.x)
            cells[index].spiceAmount = max(cells[index].spiceAmount, 1)
        }
        for packed in field.initialBlooms {
            let tile = PackedPosition(raw: packed).tile
            let index = Int(tile.y) * Self.width + Int(tile.x)
            cells[index].groundTileID = resolver.bloomTileID
        }
        for packed in field.initialSpecials {
            let tile = PackedPosition(raw: packed).tile
            let index = Int(tile.y) * Self.width + Int(tile.x)
            // "Special" tiles are rare scenario decorations; we mark them
            // as having a structure slot reserved so they're not paved.
            cells[index].hasStructure = true
        }
    }
}
