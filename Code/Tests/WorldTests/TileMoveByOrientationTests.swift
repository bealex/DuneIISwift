import Testing

@testable import DuneIIWorld

/// `Tile_MoveByOrientation` (`tile.c:405`): a whole-tile step along the 8-step facing. The bit-exact
/// trajectory parity lives in `ScenarioGoldenTests.moving` (via `Unit_StartMovement`); this pins the
/// eight direction vectors + the out-of-map clamp directly.
@Suite("Tile_MoveByOrientation")
struct TileMoveByOrientationTests {
    @Test("each 8-dir facing steps one tile in the right direction")
    func eightDirections() {
        let start = Tile32.unpack(Tile32.packXY(x: 16, y: 16))  // centred tile (16, 16)
        // orientation256 (nearest 8-dir), expected (Δtx, Δty).
        let cases: [(UInt8, Int, Int)] = [
            (0, 0, -1),  // N
            (32, 1, -1),  // NE
            (64, 1, 0),  // E
            (96, 1, 1),  // SE
            (128, 0, 1),  // S
            (160, -1, 1),  // SW
            (192, -1, 0),  // W
            (224, -1, -1),  // NW
        ]
        for (orient, dtx, dty) in cases {
            let moved = Tile32.moveByOrientation(start, orientation: orient)
            #expect(Int(moved.posX) == 16 + dtx, "orient \(orient) x")
            #expect(Int(moved.posY) == 16 + dty, "orient \(orient) y")
            #expect(moved.x & 0xFF == start.x & 0xFF)  // sub-tile offset preserved
        }
    }

    @Test("a step off the map edge returns the input position")
    func outOfMap() {
        let topRow = Tile32.unpack(Tile32.packXY(x: 5, y: 0))  // y tile 0
        #expect(Tile32.moveByOrientation(topRow, orientation: 0) == topRow)  // N would underflow
        let leftCol = Tile32.unpack(Tile32.packXY(x: 0, y: 5))  // x tile 0
        #expect(Tile32.moveByOrientation(leftCol, orientation: 192) == leftCol)  // W would underflow
    }
}
