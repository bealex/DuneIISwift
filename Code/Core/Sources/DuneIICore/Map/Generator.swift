import Foundation

extension Map {
    /// Deterministic terrain generator. Given a 32-bit scenario seed and a
    /// `TileResolver`, produces a fresh 64×64 `Map` whose ground tile IDs
    /// are bit-for-bit identical to OpenDUNE's `Map_CreateLandscape`.
    /// See `Documentation/Algorithms/MapGenerator.md` for the algorithm.
    public enum Generator {
        public static func generate(seed: UInt32, resolver: TileResolver) -> Map {
            var rng = RNG.ToolsRandom256(seed: seed)

            // Step 1: 273-byte noise pool. Only 0..271 filled here; the
            // spread passes can mutate up to index 272 via clamping.
            var memory = [Int](repeating: 0, count: 273)
            for i in 0..<272 {
                var v = Int(rng.next()) & 0xF
                if v > 0xA { v = 0xA }
                memory[i] = v
            }

            // Step 2: additive blob pass.
            var iterations = (Int(rng.next()) & 0xF) + 1
            while iterations > 0 {
                let base = Int(rng.next())
                for off in around {
                    let index = min(max(0, base + off), 272)
                    memory[index] = (memory[index] + (Int(rng.next()) & 0xF)) & 0xF
                }
                iterations -= 1
            }

            // Step 3: subtractive ("anti-blob") pass.
            iterations = (Int(rng.next()) & 0x3) + 1
            while iterations > 0 {
                let base = Int(rng.next())
                for off in around {
                    let index = min(max(0, base + off), 272)
                    memory[index] = Int(rng.next()) & 0x3
                }
                iterations -= 1
            }

            // Working grid: 4096 ints. Holds raw 0..15, then LST_*, then 0..80 sprite ids.
            var grid = [Int](repeating: 0, count: 4096)

            // Step 4: stamp the 16×16 anchor grid.
            for j in 0..<16 {
                for i in 0..<16 {
                    grid[packXY(i * 4, j * 4)] = memory[j * 16 + i]
                }
            }

            // Step 5: bilinear fill of the 4-pixel gaps.
            for j in 0..<16 {
                for i in 0..<16 {
                    let table = offsetTable[(i + 1) % 2]
                    for k in 0..<21 {
                        let off = table[k]
                        let p1Raw = packXY(i * 4 + off[0], j * 4 + off[1])
                        let p2Raw = packXY(i * 4 + off[2], j * 4 + off[3])
                        let dst = (p1Raw + p2Raw) / 2
                        if dst & 0xF000 != 0 { continue }

                        let p1 = packXY((i * 4 + off[0]) & 0x3F, j * 4 + off[1])
                        let p2 = packXY((i * 4 + off[2]) & 0x3F, j * 4 + off[3])
                        let sprite2 = (p2 < 4096) ? grid[p2] : 0
                        grid[dst] = (grid[p1] + sprite2 + 1) / 2
                    }
                }
            }

            // Step 6: 9-neighbour averaging (inclusive of self). Uses the
            // same row-snapshot trick OpenDUNE does so the read/write
            // happens against the *previous* row.
            var currentRow = [Int](repeating: 0, count: 64)
            var previousRow = [Int](repeating: 0, count: 64)
            for j in 0..<64 {
                previousRow = currentRow
                let rowStart = j * 64
                for i in 0..<64 { currentRow[i] = grid[rowStart + i] }
                for i in 0..<64 {
                    let n0 = (i == 0  || j == 0)  ? currentRow[i] : previousRow[i - 1]
                    let n1 = (             j == 0)  ? currentRow[i] : previousRow[i]
                    let n2 = (i == 63 || j == 0)  ? currentRow[i] : previousRow[i + 1]
                    let n3 = (i == 0)             ? currentRow[i] : currentRow[i - 1]
                    let n4 =                        currentRow[i]
                    let n5 = (i == 63)            ? currentRow[i] : currentRow[i + 1]
                    let n6 = (i == 0  || j == 63) ? currentRow[i] : grid[rowStart + i + 63]
                    let n7 = (             j == 63) ? currentRow[i] : grid[rowStart + i + 64]
                    let n8 = (i == 63 || j == 63) ? currentRow[i] : grid[rowStart + i + 65]
                    grid[rowStart + i] = (n0 + n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8) / 9
                }
            }

            // Step 7: threshold into landscape types.
            var spriteID1 = Int(rng.next()) & 0xF
            if spriteID1 < 0x8 { spriteID1 = 0x8 }
            if spriteID1 > 0xC { spriteID1 = 0xC }
            // (Tools_Random_256() & 3) - 1 — interpret as signed int16.
            var spriteID2 = (Int(rng.next()) & 0x3) - 1
            if spriteID2 > spriteID1 - 3 { spriteID2 = spriteID1 - 3 }

            for i in 0..<4096 {
                let v = grid[i]
                if v > spriteID1 + 4 {
                    grid[i] = lstEntirelyMountain
                } else if v >= spriteID1 {
                    grid[i] = lstEntirelyRock
                } else if v <= spriteID2 {
                    grid[i] = lstEntirelyDune
                } else {
                    grid[i] = lstNormalSand
                }
            }

            // Step 8: spice sprinkling.
            var outerRemaining = Int(rng.next()) & 0x2F
            while outerRemaining > 0 {
                outerRemaining -= 1
                var packed = 0
                while true {
                    let y = Int(rng.next()) & 0x3F
                    let x = Int(rng.next()) & 0x3F
                    packed = packXY(x, y)
                    if canBecomeSpice(grid[packed]) { break }
                }
                let tile = unpackTile(packed)
                var innerRemaining = Int(rng.next()) & 0x1F
                while innerRemaining > 0 {
                    innerRemaining -= 1
                    var movedPacked = 0
                    while true {
                        let distArg = Int(rng.next()) & 0x3F
                        let moved = moveByRandom(tile, distance: distArg, center: true, rng: &rng)
                        movedPacked = packTile(moved)
                        if movedPacked & 0xF000 == 0 { break }
                    }
                    addSpiceOnTile(grid: &grid, packed: movedPacked)
                }
            }

            // Step 9: rebuild row snapshots for the sprite-index pass.
            currentRow = [Int](repeating: 0, count: 64)
            previousRow = [Int](repeating: 0, count: 64)
            for j in 0..<64 {
                previousRow = currentRow
                let rowStart = j * 64
                for i in 0..<64 { currentRow[i] = grid[rowStart + i] }
                for i in 0..<64 {
                    let current = currentRow[i]
                    let up    = (j == 0)  ? current : previousRow[i]
                    let right = (i == 63) ? current : currentRow[i + 1]
                    let down  = (j == 63) ? current : grid[rowStart + i + 64]
                    let left  = (i == 0)  ? current : currentRow[i - 1]

                    var sprite = 0
                    if up    == current { sprite |= 1 }
                    if right == current { sprite |= 2 }
                    if down  == current { sprite |= 4 }
                    if left  == current { sprite |= 8 }

                    switch current {
                    case lstNormalSand:
                        sprite = 0
                    case lstEntirelyRock:
                        if up    == lstEntirelyMountain { sprite |= 1 }
                        if right == lstEntirelyMountain { sprite |= 2 }
                        if down  == lstEntirelyMountain { sprite |= 4 }
                        if left  == lstEntirelyMountain { sprite |= 8 }
                        sprite += 1
                    case lstEntirelyDune:
                        sprite += 17
                    case lstEntirelyMountain:
                        sprite += 33
                    case lstSpice:
                        if up    == lstThickSpice { sprite |= 1 }
                        if right == lstThickSpice { sprite |= 2 }
                        if down  == lstThickSpice { sprite |= 4 }
                        if left  == lstThickSpice { sprite |= 8 }
                        sprite += 49
                    case lstThickSpice:
                        sprite += 65
                    default: break
                    }
                    grid[rowStart + i] = sprite
                }
            }

            // Step 10: resolve through the LANDSCAPE icon group.
            var cells = [Map.Cell](repeating: Map.Cell(), count: 4096)
            for i in 0..<4096 {
                let tileID = resolver.iconMap.tileId(in: .landscape, offset: grid[i])
                cells[i].groundTileID = tileID
            }
            return Map(cells: cells)
        }
    }
}

// MARK: - Tile helpers (mirrors of OpenDUNE src/tile.h macros)

@inline(__always)
private func packXY(_ x: Int, _ y: Int) -> Int { (y << 6) | x }

@inline(__always)
private func packTile(_ tile: (x: Int, y: Int)) -> Int {
    let posX = (tile.x >> 8) & 0x3F
    let posY = (tile.y >> 8) & 0x3F
    return (posY << 6) | posX
}

@inline(__always)
private func unpackTile(_ packed: Int) -> (x: Int, y: Int) {
    let x = ((packed & 0x3F) << 8) | 0x80
    let y = (((packed >> 6) & 0x3F) << 8) | 0x80
    return (x, y)
}

/// Mirror of OpenDUNE `Tile_MoveByRandom`. Consumes 0 RNG bytes if
/// `distance == 0`, otherwise 2 (one for the per-call distance roll,
/// one for the orientation index).
private func moveByRandom(
    _ tile: (x: Int, y: Int),
    distance distanceArg: Int,
    center: Bool,
    rng: inout RNG.ToolsRandom256
) -> (x: Int, y: Int) {
    if distanceArg == 0 { return tile }

    var dist = Int(rng.next())
    while dist > distanceArg { dist /= 2 }
    let orientation = Int(rng.next())

    let stepX = Int(stepXTable[orientation])
    let stepY = Int(stepYTable[orientation])
    let newX = tile.x + (stepX * dist / 128) * 16
    let newY = tile.y - (stepY * dist / 128) * 16

    // OpenDUNE checks `> 16384` against uint16; underflow there wraps
    // to a huge value, also failing the check. We're using signed Int,
    // so we explicitly reject the negative case too.
    if newX < 0 || newY < 0 || newX > 16384 || newY > 16384 { return tile }

    var result = (x: newX, y: newY)
    if center {
        result.x = (result.x & 0xFF00) | 0x80
        result.y = (result.y & 0xFF00) | 0x80
    }
    return result
}

// MARK: - Spice spread (mirror of `Map_AddSpiceOnTile`)

private let lstNormalSand = 0
private let lstEntirelyDune = 2
private let lstEntirelyRock = 4
private let lstEntirelyMountain = 6
private let lstSpice = 8
private let lstThickSpice = 9

@inline(__always)
private func canBecomeSpice(_ landscape: Int) -> Bool {
    switch landscape {
    case lstNormalSand, lstEntirelyDune, 3, lstSpice, lstThickSpice: return true
    default: return false
    }
}

private func addSpiceOnTile(grid: inout [Int], packed: Int) {
    switch grid[packed] {
    case lstSpice:
        grid[packed] = lstThickSpice
        addSpiceOnTile(grid: &grid, packed: packed)
    case lstThickSpice:
        let cx = packed & 0x3F
        let cy = (packed >> 6) & 0x3F
        for dj in -1...1 {
            for di in -1...1 {
                let nx = cx + di
                let ny = cy + dj
                // Mirrors the C macro `Tile_PackXY((y+j) << 6 | (x+i))`
                // truncated to uint16. Negative x-overflow sets the
                // high nibble; positive y-overflow shifts past bit 12.
                // Both cases trip the `0xF000` Out-of-map bit.
                let raw = ((ny << 6) | nx) & 0xFFFF
                if raw & 0xF000 != 0 { continue }
                if !canBecomeSpice(grid[raw]) {
                    grid[packed] = lstSpice
                    continue
                }
                if grid[raw] != lstThickSpice { grid[raw] = lstSpice }
            }
        }
    default:
        if canBecomeSpice(grid[packed]) { grid[packed] = lstSpice }
    }
}

// MARK: - Tables

private let around: [Int] = [
    0, -1, 1, -16, 16, -17, 17, -15, 15, -2, 2,
    -32, 32, -4, 4, -64, 64, -30, 30, -34, 34,
]

private let offsetTable: [[[Int]]] = [
    [
        [0, 0, 4, 0], [4, 0, 4, 4], [0, 0, 0, 4], [0, 4, 4, 4], [0, 0, 0, 2],
        [0, 2, 0, 4], [0, 0, 2, 0], [2, 0, 4, 0], [4, 0, 4, 2], [4, 2, 4, 4],
        [0, 4, 2, 4], [2, 4, 4, 4], [0, 0, 4, 4], [2, 0, 2, 2], [0, 0, 2, 2],
        [4, 0, 2, 2], [0, 2, 2, 2], [2, 2, 4, 2], [2, 2, 0, 4], [2, 2, 4, 4],
        [2, 2, 2, 4],
    ],
    [
        [0, 0, 4, 0], [4, 0, 4, 4], [0, 0, 0, 4], [0, 4, 4, 4], [0, 0, 0, 2],
        [0, 2, 0, 4], [0, 0, 2, 0], [2, 0, 4, 0], [4, 0, 4, 2], [4, 2, 4, 4],
        [0, 4, 2, 4], [2, 4, 4, 4], [4, 0, 0, 4], [2, 0, 2, 2], [0, 0, 2, 2],
        [4, 0, 2, 2], [0, 2, 2, 2], [2, 2, 4, 2], [2, 2, 0, 4], [2, 2, 4, 4],
        [2, 2, 2, 4],
    ],
]

/// 256-entry table copied from OpenDUNE `src/tile.c::_stepX`.
private let stepXTable: [Int8] = [
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

/// 256-entry table copied from OpenDUNE `src/tile.c::_stepY`.
private let stepYTable: [Int8] = [
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
       0,    3,    6,    9,   12,   15,   18,   21,   24,   27,   30,   33,   36,   39,   42,   45,
      48,   51,   54,   57,   59,   62,   65,   67,   70,   73,   75,   78,   80,   82,   85,   87,
      89,   91,   94,   96,   98,  100,  101,  103,  105,  107,  108,  110,  111,  113,  114,  116,
     117,  118,  119,  120,  121,  122,  123,  123,  124,  125,  125,  126,  126,  126,  126,  126,
]
