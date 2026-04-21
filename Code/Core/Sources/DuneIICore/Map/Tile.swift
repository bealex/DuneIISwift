import Foundation

/// Pixel-scale tile coordinates (`tile32` in OpenDUNE). Every 16×16 map
/// tile occupies 256×256 pixels; the lower 8 bits of `x` / `y` encode the
/// sub-tile offset. Pure value type; positions live on pool slots.
public struct Pos32: Sendable, Equatable, Hashable {
    public var x: UInt16
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }

    /// Tile-centered pos32 for a packed-position tile: each tile is
    /// 256 pixels, centre is at +128 / +128. Port of
    /// `Tile_Center(Tile_UnpackTile(packed))`.
    public static func centered(at packed: PackedPosition) -> Pos32 {
        let t = packed.tile
        return Pos32(
            x: UInt16(t.x) &* 256 &+ 128,
            y: UInt16(t.y) &* 256 &+ 128
        )
    }

    /// Port of OpenDUNE `Tile_GetDistance` (`src/tile.c`). Not Euclidean —
    /// it's `longest_axis + shortest_axis / 2`, matching the movement
    /// cost metric used by both pathfinding and script distance checks.
    public static func distance(_ a: Pos32, _ b: Pos32) -> UInt16 {
        let dx = Int32(a.x) - Int32(b.x)
        let dy = Int32(a.y) - Int32(b.y)
        let adx = abs(dx)
        let ady = abs(dy)
        let longest = max(adx, ady)
        let shortest = min(adx, ady)
        return UInt16(truncatingIfNeeded: longest + shortest / 2)
    }

    /// Port of OpenDUNE `Tile_GetDistanceRoundedUp` (`src/tile.c:103`):
    /// `(distance + 128) >> 8`. Drops the sub-tile fraction with
    /// half-tile rounding, giving the "tiles away" metric used by the
    /// target-priority functions.
    public static func distanceRoundedUp(_ a: Pos32, _ b: Pos32) -> UInt16 {
        let raw = UInt32(distance(a, b))
        return UInt16(truncatingIfNeeded: (raw &+ 0x80) >> 8)
    }

    /// Port of `Tile_MoveByDirection` (`src/tile.c:276`). Offsets the
    /// position by `distance` pos32 pixels along the 256-step orientation
    /// heading. `distance` is clamped to 0xFF. The sign convention matches
    /// OpenDUNE (screen y grows downward, so `y` decreases for "up"
    /// orientations).
    public static func moved(_ origin: Pos32, orientation: UInt8, distance: UInt32) -> Pos32 {
        let d = min(distance, 0xFF)
        if d == 0 { return origin }
        let i = Int(orientation)
        let diffX = Int(stepX[i])
        let diffY = Int(stepX[(i + 64) & 0xFF])   // _stepY[i] == _stepX[(i+64) & 0xFF]
        let rx = diffX < 0 ? -64 : 64
        let ry = diffY < 0 ? -64 : 64
        let nx = Int32(origin.x) &+ Int32((diffX * Int(d) + rx) / 128)
        let ny = Int32(origin.y) &- Int32((diffY * Int(d) + ry) / 128)
        return Pos32(x: UInt16(truncatingIfNeeded: nx), y: UInt16(truncatingIfNeeded: ny))
    }

    /// Port of `Tile_MoveByRandom` (`src/tile.c:306`). Drifts a position
    /// by a random distance up to `distance` in a random orientation.
    /// Draws exactly 2 bytes from `random` (matching OpenDUNE's RNG
    /// consumption). When `center` is true, snaps the result to the
    /// nearest tile centre. Returns `origin` unchanged if the result
    /// would leave the 16384×16384 pos32 map.
    public static func movedRandomly(
        from origin: Pos32,
        distance: UInt16,
        center: Bool,
        random: () -> UInt8
    ) -> Pos32 {
        if distance == 0 { return origin }
        var newDistance = UInt16(random())
        while newDistance > distance { newDistance /= 2 }
        let d = UInt32(newDistance)
        let orientation = Int(random())
        let diffX = Int(stepX[orientation])
        let diffY = Int(stepX[(orientation + 64) & 0xFF])
        let nx = Int(origin.x) &+ ((diffX * Int(d)) / 128) * 16
        let ny = Int(origin.y) &- ((diffY * Int(d)) / 128) * 16
        if nx < 0 || ny < 0 || nx > 16384 || ny > 16384 { return origin }
        var res = Pos32(x: UInt16(truncatingIfNeeded: nx), y: UInt16(truncatingIfNeeded: ny))
        if center {
            res = Pos32(x: (res.x & 0xFF00) | 0x80, y: (res.y & 0xFF00) | 0x80)
        }
        return res
    }

    /// OpenDUNE `_stepX` table (`src/tile.c:230`). 256-entry sin-like
    /// lookup. `_stepY[i]` is `_stepX[(i + 64) & 0xFF]` so we store one
    /// table and derive the other.
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
         -48,  -45,  -42,  -39,  -36,  -33,  -30,  -27,  -24,  -21,  -18,  -15,  -12,   -9,   -6,   -3
    ]


    /// Port of OpenDUNE `Tile_GetDirection` (`src/tile.c:342`). Returns a
    /// 0..255 heading (256-byte angle) from `from` to `to`. Used by
    /// `Script_Unit_SetTarget` / `Script_Structure_GetDirection`.
    public static func direction(from: Pos32, to: Pos32) -> UInt8 {
        let orientationOffsets: [UInt16] = [0x40, 0x80, 0x00, 0xC0]
        let directions: [Int32] = [
            0x3FFF, 0x28BC, 0x145A, 0xD8E,  0xA27, 0x81B, 0x6BD, 0x5C3,
            0x506, 0x474, 0x3FE, 0x39D,  0x34B, 0x306, 0x2CB, 0x297,
            0x26A, 0x241, 0x21D, 0x1FC,  0x1DE, 0x1C3, 0x1AB, 0x194,
            0x17F, 0x16B, 0x159, 0x148,  0x137, 0x128, 0x11A, 0x10C
        ]

        var dx = Int32(to.x) - Int32(from.x)
        var dy = Int32(to.y) - Int32(from.y)
        if abs(dx) + abs(dy) > 8000 {
            dx /= 2
            dy /= 2
        }

        var quadrant: UInt16 = 0
        if dy <= 0 {
            quadrant |= 0x2
            dy = -dy
        }
        if dx < 0 {
            quadrant |= 0x1
            dx = -dx
        }

        let baseOrientation = orientationOffsets[Int(quadrant)]
        var invert = false
        var gradient: Int32 = 0x7FFF

        if dx >= dy {
            if dy != 0 { gradient = (dx << 8) / dy }
        } else {
            invert = true
            if dx != 0 { gradient = (dy << 8) / dx }
        }

        var i: Int = 0
        while i < directions.count {
            if directions[i] <= gradient { break }
            i &+= 1
        }

        if !invert { i = 64 - i }

        let value: Int
        if quadrant == 0 || quadrant == 3 {
            value = (Int(baseOrientation) + 64 - i) & 0xFF
        } else {
            value = (Int(baseOrientation) + i) & 0xFF
        }
        return UInt8(truncatingIfNeeded: value)
    }

    /// Tile32 position of the tile referenced by an `EncodedIndex`.
    /// - `.tile`: centred on the packed tile coordinates.
    /// - `.unit` / `.structure`: the pool slot's `positionX` / `positionY`.
    /// - `.none`: nil.
    public static func of(_ encoded: Scripting.EncodedIndex, host: Scripting.Host) -> Pos32? {
        switch encoded.kind {
        case .none:
            return nil
        case .tile:
            let packed = PackedPosition(raw: encoded.decoded)
            return Pos32.centered(at: packed)
        case .unit:
            let idx = Int(encoded.decoded)
            guard idx < host.units.slots.count else { return nil }
            let s = host.units.slots[idx]
            guard s.isUsed, s.isAllocated else { return nil }
            return Pos32(x: s.positionX, y: s.positionY)
        case .structure:
            let idx = Int(encoded.decoded)
            guard idx < host.structures.slots.count else { return nil }
            let s = host.structures.slots[idx]
            guard s.isUsed else { return nil }
            return Pos32(x: s.positionX, y: s.positionY)
        }
    }
}
