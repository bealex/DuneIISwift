/// A 2D size in tiles. A literal port of OpenDUNE's `XYSize` (`src/structure.h:118`).
public struct XYSize: Sendable, Equatable {
    public let width: UInt16
    public let height: UInt16

    public init(width: UInt16, height: UInt16) { self.width = width; self.height = height }
}

/// Per-layout structure geometry. A literal port of OpenDUNE's `g_table_structure_layout*` tables
/// (`src/table/structureinfo.c`), consolidated and keyed by `StructureLayout`. These drive
/// `Structure_UpdateMap`, build-location validity, and wall connection.
///
/// All offsets are added to a structure's top-left packed tile; `+64` steps one map row down (the map
/// is 64 tiles wide). Verified field-for-field against an OpenDUNE golden dump — see
/// `Documentation/Algorithms/StatTables.md`.
public struct StructureLayoutInfo: Sendable, Equatable {
    public let tiles: [UInt16]  // 9: packed-tile offset of each tile in the layout
    public let edgeTiles: [UInt16]  // 8: offsets of the edge tiles (used by wall connection)
    public let tileCount: UInt16  // number of tiles actually occupied
    public let tileDiff: Tile32  // sub-tile (tile32) extent of the whole layout
    public let size: XYSize  // width × height in tiles
    public let tilesAround: [Int16]  // 16: offsets of the ring of tiles surrounding the layout

    /// Geometry for `layout`.
    public static subscript(_ layout: StructureLayout) -> StructureLayoutInfo { table[layout.rawValue] }

    /// `g_table_structure_layout*[]`, indexed by `StructureLayout.rawValue`.
    public static let table: [StructureLayoutInfo] = [
        entry(  // 0 layout1x1
            tiles: [ 0, 0, 0, 0, 0, 0, 0, 0, 0 ],
            edgeTiles: [ 0, 0, 0, 0, 0, 0, 0, 0 ],
            tileCount: 1,
            tileDiff: Tile32(x: 128, y: 128),
            size: XYSize(width: 1, height: 1),
            tilesAround: [ -64, -63, 1, 65, 64, 63, -1, -65, 0, 0, 0, 0, 0, 0, 0, 0 ]
        ),
        entry(  // 1 layout2x1
            tiles: [ 0, 1, 0, 0, 0, 0, 0, 0, 0 ],
            edgeTiles: [ 0, 1, 1, 1, 1, 0, 0, 0 ],
            tileCount: 2,
            tileDiff: Tile32(x: 256, y: 128),
            size: XYSize(width: 2, height: 1),
            tilesAround: [ -64, -63, -62, 2, 66, 65, 64, 63, -1, -65, 0, 0, 0, 0, 0, 0 ]
        ),
        entry(  // 2 layout1x2
            tiles: [ 0, 64, 0, 0, 0, 0, 0, 0, 0 ],
            edgeTiles: [ 0, 0, 0, 64, 64, 64, 0, 0 ],
            tileCount: 2,
            tileDiff: Tile32(x: 128, y: 256),
            size: XYSize(width: 1, height: 2),
            tilesAround: [ -64, -63, 1, 65, 129, 128, 127, 63, -1, -65, 0, 0, 0, 0, 0, 0 ]
        ),
        entry(  // 3 layout2x2
            tiles: [ 0, 1, 64, 65, 0, 0, 0, 0, 0 ],
            edgeTiles: [ 0, 1, 1, 65, 65, 64, 64, 0 ],
            tileCount: 4,
            tileDiff: Tile32(x: 256, y: 256),
            size: XYSize(width: 2, height: 2),
            tilesAround: [ -64, -63, -62, 2, 66, 130, 129, 128, 127, 63, -1, -65, 0, 0, 0, 0 ]
        ),
        entry(  // 4 layout2x3
            tiles: [ 0, 1, 64, 65, 128, 129, 0, 0, 0 ],
            edgeTiles: [ 0, 1, 65, 129, 129, 128, 64, 0 ],
            tileCount: 6,
            tileDiff: Tile32(x: 256, y: 384),
            size: XYSize(width: 2, height: 3),
            tilesAround: [ -64, -63, -62, 2, 66, 130, 194, 193, 192, 191, 127, 63, -1, -65, 0, 0 ]
        ),
        entry(  // 5 layout3x2
            tiles: [ 0, 1, 2, 64, 65, 66, 0, 0, 0 ],
            edgeTiles: [ 1, 2, 2, 66, 65, 64, 0, 0 ],
            tileCount: 6,
            tileDiff: Tile32(x: 640, y: 256),
            size: XYSize(width: 3, height: 2),
            tilesAround: [ -64, -63, -62, -61, 3, 67, 131, 130, 129, 128, 127, 63, -1, -65, 0, 0 ]
        ),
        entry(  // 6 layout3x3
            tiles: [ 0, 1, 2, 64, 65, 66, 128, 129, 130 ],
            edgeTiles: [ 1, 2, 66, 130, 129, 128, 64, 0 ],
            tileCount: 9,
            tileDiff: Tile32(x: 384, y: 384),
            size: XYSize(width: 3, height: 3),
            tilesAround: [ -64, -63, -62, -61, 3, 67, 131, 195, 194, 193, 192, 191, 127, 63, -1, -65 ]
        ),
    ]

    private static func entry(
        tiles: [UInt16],
        edgeTiles: [UInt16],
        tileCount: UInt16,
        tileDiff: Tile32,
        size: XYSize,
        tilesAround: [Int16]
    ) -> StructureLayoutInfo {
        StructureLayoutInfo(
            tiles: tiles,
            edgeTiles: edgeTiles,
            tileCount: tileCount,
            tileDiff: tileDiff,
            size: size,
            tilesAround: tilesAround
        )
    }
}
