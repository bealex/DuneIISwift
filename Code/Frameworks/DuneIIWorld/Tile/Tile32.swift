/// A 32-bit map position: `x` and `y` are each 16-bit fixed-point — the high byte is the tile
/// coordinate (0...63), the low byte the sub-tile offset (tile centre is `0x80`). A bit-exact port of
/// OpenDUNE's `tile32` (`include/types.h:102`) and the pure geometry in `src/tile.c` / `src/tile.h`.
/// "Packed" tiles are the 12-bit `(y << 6) | x` form used by the map and many script functions.
///
/// Verified against an OpenDUNE golden dump — see `Documentation/Algorithms/Tile.md`.
public struct Tile32: Equatable, Sendable, Codable {
    public var x: UInt16
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }

    /// `Tile_IsValid`: both coordinates inside the 14-bit map space (bits 14-15 clear).
    public var isValid: Bool { ((x | y) & 0xC000) == 0 }

    /// `Tile_GetPosX` / `Tile_GetPosY`: the 0...63 tile coordinate (high byte, low 6 bits).
    public var posX: UInt8 { UInt8((x >> 8) & 0x3F) }
    public var posY: UInt8 { UInt8((y >> 8) & 0x3F) }

    /// `Tile_PackTile`: the 12-bit packed form `(posY << 6) | posX`.
    public var packed: UInt16 { (UInt16(posY) << 6) | UInt16(posX) }

    /// `Tile_GetPackedX` / `Tile_GetPackedY` on a packed tile.
    public static func packedX(_ packed: UInt16) -> UInt8 { UInt8(packed & 0x3F) }
    public static func packedY(_ packed: UInt16) -> UInt8 { UInt8((packed >> 6) & 0x3F) }

    /// `Tile_PackXY`: pack 0...63 tile coordinates into the 12-bit `(y << 6) | x` form.
    public static func packXY(x: UInt16, y: UInt16) -> UInt16 { (y << 6) | x }

    /// `Tile_UnpackTile`: a packed tile to a centred `tile32` (sub-tile offset `0x80`).
    public static func unpack(_ packed: UInt16) -> Tile32 {
        Tile32(
            x: (UInt16(packed & 0x3F) << 8) | 0x80,
            y: (UInt16((packed >> 6) & 0x3F) << 8) | 0x80
        )
    }

    /// `Tile_AddTileDiff`: component-wise add of a tile diff. Wrapping `uint16`, as in the original.
    public static func addDiff(_ from: Tile32, _ diff: Tile32) -> Tile32 {
        Tile32(x: from.x &+ diff.x, y: from.y &+ diff.y)
    }

    /// `Tile_Center`: snap both axes' sub-tile offset to the tile centre (`0x80`).
    public var centered: Tile32 { Tile32(x: (x & 0xFF00) | 0x80, y: (y & 0xFF00) | 0x80) }

    /// `Tile_IsOutOfMap`: a packed tile outside the 64×64 map (any of bits 12-15 set).
    public static func isOutOfMap(_ packed: UInt16) -> Bool { (packed & 0xF000) != 0 }

    /// `Tile_MoveByDirection` (`tile.c:276`): move `tile` by `distance` (clamped to 255) sub-tile units
    /// along the 256-step `orientation`, rounding each axis away from zero. `_stepY[i] == _stepX[i+64]`.
    public static func moveByDirection(_ tile: Tile32, orientation: Int16, distance: UInt16) -> Tile32 {
        let dist = Int(Swift.min(distance, 0xFF))
        if dist == 0 { return tile }
        let idx = Int(UInt8(truncatingIfNeeded: orientation))          // orientation & 0xFF
        let diffX = Int(stepX[idx])
        let diffY = Int(stepX[(idx + 64) & 0xFF])                      // _stepY
        let roundX = diffX < 0 ? -64 : 64
        let roundY = diffY < 0 ? -64 : 64
        return Tile32(
            x: UInt16(truncatingIfNeeded: Int(tile.x) + (diffX * dist + roundX) / 128),
            y: UInt16(truncatingIfNeeded: Int(tile.y) - (diffY * dist + roundY) / 128))
    }

    /// `Map_IsPositionInViewport` (`map.c:363`): is `position` within the screen viewport whose top-left
    /// packed tile is `viewport`? Used by `GameLoop_Unit` to throttle off-screen units' scripting.
    public static func isPositionInViewport(_ position: Tile32, viewport: UInt16) -> Bool {
        let x = Int16(truncatingIfNeeded: Int(position.x >> 4) - (Int(packedX(viewport)) << 4))
        let y = Int16(truncatingIfNeeded: Int(position.y >> 4) - (Int(packedY(viewport)) << 4))
        return x >= -16 && x <= 256 && y >= -16 && y <= 176
    }

    /// `Tile_MoveByOrientation` (`tile.c:405`): step `position` one whole tile (256 sub-units) along the
    /// 8-step facing of `orientation`. Returns the input position unchanged if the step leaves the map.
    public static func moveByOrientation(_ position: Tile32, orientation: UInt8) -> Tile32 {
        let xOffsets: [Int] = [0, 256, 256, 256, 0, -256, -256, -256]
        let yOffsets: [Int] = [-256, -256, 0, 256, 256, 256, 0, -256]
        let o8 = Int(Orientation.to8(orientation))
        // uint16 arithmetic (the original adds wrapped uint16 offsets), then the out-of-map check.
        let x = UInt16(truncatingIfNeeded: Int(position.x) + xOffsets[o8])
        let y = UInt16(truncatingIfNeeded: Int(position.y) + yOffsets[o8])
        if x > 16384 || y > 16384 { return position }
        return Tile32(x: x, y: y)
    }

    /// `Tile_MoveByRandom` (`tile.c`): pick a random distance (≤ `distance`, halved down from a random
    /// byte) and a random 256-step orientation, then offset `tile` by whole tiles in that direction.
    /// Draws two `Random256` bytes from `rng`; returns the original tile if the result leaves the map.
    public static func moveByRandom(
        _ tile: Tile32, distance: UInt16, center: Bool, rng: inout Random256
    ) -> Tile32 {
        if distance == 0 { return tile }

        var newDistance = UInt16(rng.next())
        while newDistance > distance { newDistance /= 2 }
        let dist = Int(newDistance)

        let orientation = Int(rng.next())
        let x = UInt16(truncatingIfNeeded: Int(tile.x) + ((Int(stepX[orientation]) * dist) / 128) * 16)
        let y = UInt16(truncatingIfNeeded: Int(tile.y) - ((Int(stepX[(orientation + 64) & 0xFF]) * dist) / 128) * 16)

        if x > 16384 || y > 16384 { return tile }
        let result = Tile32(x: x, y: y)
        return center ? result.centered : result
    }

    /// `_stepX[256]` (`tile.c:230`): the signed cos-like step table. `_stepY[i] = stepX[(i + 64) & 0xFF]`.
    static let stepX: [Int8] = [
           0,    3,    6,    9,   12,   15,   18,   21,   24,   27,   30,   33,   36,   39,   42,   45,
          48,   51,   54,   57,   59,   62,   65,   67,   70,   73,   75,   78,   80,   82,   85,   87,
          89,   91,   94,   96,   98,  100,  101,  103,  105,  107,  108,  110,  111,  113,  114,  116,
         117,  118,  119,  120,  121,  122,  123,  123,  124,  125,  125,  126,  126,  126,  126,  126,
         127,  126,  126,  126,  126,  126,  125,  125,  124,  123,  123,  122,  121,  120,  119,  118,
         117,  116,  114,  113,  112,  110,  108,  107,  105,  103,  102,  100,   98,   96,   94,   91,
          89,   87,   85,   82,   80,   78,   75,   73,   70,   67,   65,   62,   59,   57,   54,   51,
          48,   45,   42,   39,   36,   33,   30,   27,   24,   21,   18,   15,   12,    9,    6,    3,
           0,   -3,   -6,   -9,  -12,  -15,  -18,  -21,  -24,  -27,  -30,  -33,  -36,  -39,  -42,  -45,
         -48,  -51,  -54,  -57,  -59,  -62,  -65,  -67,  -70,  -73,  -75,  -78,  -80,  -82,  -85,  -87,
         -89,  -91,  -94,  -96,  -98, -100, -102, -103, -105, -107, -108, -110, -111, -113, -114, -116,
        -117, -118, -119, -120, -121, -122, -123, -123, -124, -125, -125, -126, -126, -126, -126, -126,
        -126, -126, -126, -126, -126, -126, -125, -125, -124, -123, -123, -122, -121, -120, -119, -118,
        -117, -116, -114, -113, -112, -110, -108, -107, -105, -103, -102, -100,  -98,  -96,  -94,  -91,
         -89,  -87,  -85,  -82,  -80,  -78,  -75,  -73,  -70,  -67,  -65,  -62,  -59,  -57,  -54,  -51,
         -48,  -45,  -42,  -39,  -36,  -33,  -30,  -27,  -24,  -21,  -18,  -15,  -12,   -9,   -6,   -3,
    ]

    /// `Tile_GetDistance`: the longest axis distance plus half the shortest (Chebyshev-ish). Wrapping
    /// `uint16` arithmetic, as in the original.
    public static func distance(from: Tile32, to: Tile32) -> UInt16 {
        let dx = UInt16(abs(Int(from.x) - Int(to.x)))
        let dy = UInt16(abs(Int(from.y) - Int(to.y)))
        return dx > dy ? dx &+ (dy / 2) : dy &+ (dx / 2)
    }

    /// `Tile_GetDistancePacked`: distance between two packed tiles, in whole tiles (`>> 8`).
    public static func distancePacked(_ from: UInt16, _ to: UInt16) -> UInt16 {
        distance(from: unpack(from), to: unpack(to)) >> 8
    }

    /// `Tile_GetDistanceRoundedUp`: distance in whole tiles, rounded up (`+ 0x80 >> 8`).
    public static func distanceRoundedUp(from: Tile32, to: Tile32) -> UInt16 {
        (distance(from: from, to: to) &+ 0x80) >> 8
    }

    /// `Tile_GetDirectionPacked`: an 8-step direction (as a 0/0x20/.../0xE0 byte) from one packed tile
    /// toward another.
    public static func directionPacked(_ from: UInt16, _ to: UInt16) -> UInt8 {
        let returnValues: [UInt8] = [
            0x20, 0x40, 0x20, 0x00, 0xE0, 0xC0, 0xE0, 0x00, 0x60, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xA0, 0x80,
        ]
        let x1 = Int(packedX(from)), y1 = Int(packedY(from))
        let x2 = Int(packedX(to)), y2 = Int(packedY(to))

        var index = 0
        var dy = y1 - y2
        if dy < 0 { index |= 0x8; dy = -dy }
        var dx = x2 - x1
        if dx < 0 { index |= 0x4; dx = -dx }

        if dx >= dy {
            if (dx + 1) / 2 > dy { index |= 0x1 }
        } else {
            index |= 0x2
            if (dy + 1) / 2 > dx { index |= 0x1 }
        }
        return returnValues[index]
    }

    /// `Tile_GetDirection`: the precise 0...255 orientation from `from` toward `to`, via the gradient
    /// lookup table. Returns a signed byte (the original's `int8`).
    public static func direction(from: Tile32, to: Tile32) -> Int8 {
        let orientationOffsets = [0x40, 0x80, 0x0, 0xC0]
        let directions = [
            0x3FFF, 0x28BC, 0x145A, 0xD8E, 0xA27, 0x81B, 0x6BD, 0x5C3, 0x506, 0x474, 0x3FE, 0x39D, 0x34B, 0x306, 0x2CB, 0x297,
            0x26A, 0x241, 0x21D, 0x1FC, 0x1DE, 0x1C3, 0x1AB, 0x194, 0x17F, 0x16B, 0x159, 0x148, 0x137, 0x128, 0x11A, 0x10C,
        ]

        var dx = Int(to.x) - Int(from.x)
        var dy = Int(to.y) - Int(from.y)
        if abs(dx) + abs(dy) > 8000 { dx /= 2; dy /= 2 }

        var quadrant = 0
        if dy <= 0 { quadrant |= 0x2; dy = -dy }
        if dx < 0 { quadrant |= 0x1; dx = -dx }

        let baseOrientation = orientationOffsets[quadrant]
        var invert = false
        var gradient = 0x7FFF
        if dx >= dy {
            if dy != 0 { gradient = (dx << 8) / dy }
        } else {
            invert = true
            if dx != 0 { gradient = (dy << 8) / dx }
        }

        var i = 0
        while i < directions.count, directions[i] > gradient { i += 1 }
        if !invert { i = 64 - i }

        let result = (quadrant == 0 || quadrant == 3) ? (baseOrientation + 64 - i) & 0xFF : (baseOrientation + i) & 0xFF
        return Int8(truncatingIfNeeded: result)
    }
}
