import Foundation

extension Simulation {
    /// Port of OpenDUNE's `Script_Unit_Pathfinder` machinery from
    /// `src/script/unit.c:1012..1286`. Produces a sequence of 3-bit
    /// direction steps (0..7, terminated by `0xFF`) walking from
    /// `packedSrc` to `packedDst` on the 64×64 tile grid.
    ///
    /// Callers supply a `TileEnterScore` closure that wraps
    /// `Unit_GetTileEnterScore` — typically composed from a `Host` +
    /// `Map` + `TileResolver`. Returning `> 255` from the closure marks
    /// the tile as impassable.
    public enum Pathfinder {
        /// Tile-index delta per direction. 0..7 map to N, NE, E, SE, S, SW, W, NW.
        /// Matches OpenDUNE `s_mapDirection` at `src/script/unit.c:38`.
        public static let mapDirection: [Int32] = [-64, -63, 1, 65, 64, 63, -1, -65]

        /// Score signature: given a packed tile and the direction we're
        /// entering from (as an 8-bit orient), return the cost. 0..255 = walkable,
        /// anything higher is impassable.
        public typealias TileEnterScore = (_ packed: UInt16, _ orient8: UInt8) -> Int32

        /// Returned data — matches OpenDUNE `Pathfinder_Data`.
        public struct Route {
            public var buffer: [UInt8]        // last element is always 0xFF
            public var score: Int32
            public var size: Int              // step count excluding the 0xFF terminator
        }

        /// Top-level entry. `bufferSize` should be 40 for unit scripts
        /// (OpenDUNE allocates a 42-byte stack buffer then passes 40).
        public static func findRoute(
            src: UInt16, dst: UInt16, bufferSize: Int, score: TileEnterScore
        ) -> Route {
            var res = Route(buffer: [UInt8](repeating: 0xFF, count: bufferSize + 1), score: 0, size: 0)
            let capacity = bufferSize - 1
            var packedCur = src

            while res.size < capacity {
                if packedCur == dst { break }

                // Try going straight toward the destination.
                let direction = directionPacked(from: packedCur, to: dst) / 32
                var packedNext = UInt16(truncatingIfNeeded: Int32(packedCur) + mapDirection[Int(direction)])

                let directScore = score(packedNext, direction)
                if directScore <= 255 {
                    res.buffer[res.size] = direction
                    res.size &+= 1
                    res.score &+= directScore
                } else {
                    // Walk along the direct line to find the next walkable tile.
                    var inner = packedNext
                    var dir = direction
                    var foundCW = false
                    var foundCCW = false
                    var cwRoute = Route(buffer: [UInt8](repeating: 0xFF, count: 103), score: 0, size: 0)
                    var ccwRoute = Route(buffer: [UInt8](repeating: 0xFF, count: 103), score: 0, size: 0)

                    while true {
                        if inner == dst { break }
                        dir = directionPacked(from: inner, to: dst) / 32
                        inner = UInt16(truncatingIfNeeded: Int32(inner) + mapDirection[Int(dir)])
                        if score(inner, dir) > 255 { continue }

                        // Try to connect from our last valid tile (`packedCur`) to `inner`,
                        // both clockwise and counterclockwise.
                        ccwRoute.buffer = [UInt8](repeating: 0xFF, count: 103)
                        ccwRoute.score = 0
                        ccwRoute.size = 0
                        foundCCW = tryConnect(
                            from: packedCur, to: inner, searchDirection: -1,
                            directionStart: direction, data: &ccwRoute, score: score
                        )

                        cwRoute.buffer = [UInt8](repeating: 0xFF, count: 103)
                        cwRoute.score = 0
                        cwRoute.size = 0
                        foundCW = tryConnect(
                            from: packedCur, to: inner, searchDirection: 1,
                            directionStart: direction, data: &cwRoute, score: score
                        )

                        if foundCCW || foundCW { break }

                        // Keep sliding toward dst looking for a landable tile.
                        repeat {
                            if inner == dst { break }
                            dir = directionPacked(from: inner, to: dst) / 32
                            inner = UInt16(truncatingIfNeeded: Int32(inner) + mapDirection[Int(dir)])
                        } while score(inner, dir) <= 255
                    }

                    if foundCCW || foundCW {
                        // Pick the best (lowest-score) partial route.
                        let best: Route
                        if !foundCW { best = ccwRoute }
                        else if !foundCCW { best = cwRoute }
                        else { best = ccwRoute.score < cwRoute.score ? ccwRoute : cwRoute }
                        let canCopy = min(capacity - res.size, best.size)
                        if canCopy <= 0 { break }
                        for i in 0..<canCopy {
                            res.buffer[res.size + i] = best.buffer[i]
                        }
                        res.size &+= canCopy
                        res.score &+= best.score
                        packedNext = inner
                    } else {
                        // No route exists from packedCur; bail.
                        break
                    }
                }
                packedCur = packedNext
            }

            if res.size < capacity {
                res.buffer[res.size] = 0xFF    // ensure terminator
            }
            smoothen(&res, src: src, score: score)
            return res
        }

        // MARK: - Pathfinder_Connect

        @discardableResult
        private static func tryConnect(
            from packedSrc: UInt16,
            to packedDst: UInt16,
            searchDirection: Int8,
            directionStart startDirection: UInt8,
            data: inout Route,
            score: TileEnterScore
        ) -> Bool {
            var directionStart = startDirection
            var packedCur = packedSrc
            data.buffer = [UInt8](repeating: 0xFF, count: data.buffer.count)
            var cursor = 0
            data.score = 0

            while cursor < 100 {
                var direction = directionStart
                var packedNext: UInt16

                while true {
                    direction = UInt8((Int8(bitPattern: direction) &+ searchDirection) & 0x7)

                    // Looking directly at the destination?
                    if (direction & 0x1) != 0 {
                        let peek = UInt16(truncatingIfNeeded:
                            Int32(packedCur) + mapDirection[
                                Int(UInt8((Int8(bitPattern: direction) &+ searchDirection) & 0x7))
                            ])
                        if peek == packedDst {
                            direction = UInt8((Int8(bitPattern: direction) &+ searchDirection) & 0x7)
                            packedNext = UInt16(truncatingIfNeeded:
                                Int32(packedCur) + mapDirection[Int(direction)])
                            break
                        }
                    }
                    // Back to start direction → no route.
                    if direction == directionStart {
                        data.size = 0
                        return false
                    }
                    packedNext = UInt16(truncatingIfNeeded:
                        Int32(packedCur) + mapDirection[Int(direction)])
                    if score(packedNext, direction) <= 255 { break }
                }

                data.buffer[cursor] = direction
                cursor &+= 1

                if packedNext == packedDst {
                    data.buffer[cursor] = 0xFF
                    data.size = cursor
                    smoothen(&data, src: packedSrc, score: score)
                    if data.size > 0 { data.size &-= 1 }
                    return true
                }
                if packedSrc == packedNext {
                    data.size = 0
                    return false
                }

                // Next start direction is 3 steps back.
                directionStart = UInt8((Int8(bitPattern: direction) &- searchDirection &* 3) & 0x7)
                packedCur = packedNext
            }

            data.size = 0
            return false
        }

        // MARK: - Pathfinder_Smoothen

        private static func smoothen(_ data: inout Route, src: UInt16, score: TileEnterScore) {
            let directionOffset: [Int8] = [0, 0, 1, 2, 3, -2, -1, 0]

            // Ensure terminator at `size`.
            if data.size < data.buffer.count { data.buffer[data.size] = 0xFF }
            var packed = src

            if data.size > 1 {
                var to = 1
                while to < data.buffer.count && data.buffer[to] != 0xFF {
                    var from = to - 1
                    // Walk back over 0xFE marks.
                    while from > 0 && data.buffer[from] == 0xFE { from -= 1 }
                    if data.buffer[from] == 0xFE {
                        to += 1
                        continue
                    }

                    let rawDiff = Int8(bitPattern: data.buffer[to]) &- Int8(bitPattern: data.buffer[from])
                    let diffIdx = Int(rawDiff & 0x7)
                    let directionDelta = directionOffset[diffIdx]

                    // Opposite directions — drop both.
                    if directionDelta == 3 {
                        data.buffer[from] = 0xFE
                        data.buffer[to] = 0xFE
                        to += 1
                        continue
                    }
                    // Same direction — follow.
                    if directionDelta == 0 {
                        packed = UInt16(truncatingIfNeeded:
                            Int32(packed) + mapDirection[Int(data.buffer[from])])
                        to += 1
                        continue
                    }

                    var dir: UInt8
                    if (data.buffer[from] & 0x1) != 0 {
                        dir = UInt8(
                            (Int8(bitPattern: data.buffer[from]) &+
                                (directionDelta < 0 ? -1 : 1)) & 0x7)
                        if abs(Int(directionDelta)) == 1 {
                            let probe = UInt16(truncatingIfNeeded:
                                Int32(packed) + mapDirection[Int(dir)])
                            if score(probe, dir) <= 255 {
                                data.buffer[to] = dir
                                data.buffer[from] = dir
                            }
                            packed = UInt16(truncatingIfNeeded:
                                Int32(packed) + mapDirection[Int(data.buffer[from])])
                            to += 1
                            continue
                        }
                    } else {
                        dir = UInt8(
                            (Int8(bitPattern: data.buffer[from]) &+ directionDelta) & 0x7)
                    }

                    data.buffer[to] = dir
                    data.buffer[from] = 0xFE

                    // Walk back one step.
                    var back = from
                    while back > 0 && data.buffer[back] == 0xFE { back -= 1 }
                    if data.buffer[back] != 0xFE {
                        packed = UInt16(truncatingIfNeeded:
                            Int32(packed) + mapDirection[
                                Int(UInt8((Int8(bitPattern: data.buffer[back]) &+ 4) & 0x7))
                            ])
                    } else {
                        packed = src
                    }
                }
            }

            // Rebuild the route without 0xFE gaps.
            var writeIdx = 0
            packed = src
            data.score = 0
            var newSize = 0
            var readIdx = 0
            while readIdx < data.buffer.count && data.buffer[readIdx] != 0xFF {
                let dir = data.buffer[readIdx]
                if dir != 0xFE {
                    packed = UInt16(truncatingIfNeeded:
                        Int32(packed) + mapDirection[Int(dir)])
                    data.score &+= score(packed, dir)
                    newSize &+= 1
                    data.buffer[writeIdx] = dir
                    writeIdx &+= 1
                }
                readIdx &+= 1
            }
            newSize &+= 1
            if writeIdx < data.buffer.count { data.buffer[writeIdx] = 0xFF }
            data.size = newSize
        }

        // MARK: - Tile-packed helpers

        /// `Tile_PackTile(Pos32)` — pixel-scale `pos32` coordinates →
        /// packed tile index. Equivalent to
        /// `((x >> 8) & 0x3F) | ((y >> 8) & 0x3F) << 6`.
        public static func packedTile(x: UInt16, y: UInt16) -> UInt16 {
            let tx = UInt16((x >> 8) & 0x3F)
            let ty = UInt16((y >> 8) & 0x3F)
            return (ty << 6) | tx
        }

        /// `Tile_GetDistancePacked` — `max(|dx|, |dy|) + min(…) / 2` in
        /// tile units (6-bit x/y).
        public static func packedDistance(from: UInt16, to: UInt16) -> UInt16 {
            let x1 = Int32(from & 0x3F); let y1 = Int32((from >> 6) & 0x3F)
            let x2 = Int32(to & 0x3F);   let y2 = Int32((to >> 6) & 0x3F)
            let dx = abs(x1 - x2); let dy = abs(y1 - y2)
            return UInt16(truncatingIfNeeded: max(dx, dy) + min(dx, dy) / 2)
        }

        // MARK: - Tile_GetDirectionPacked

        /// Port of OpenDUNE `Tile_GetDirectionPacked` (`src/tile.c:193`).
        /// Returns a 256-byte angle (0..224 in steps of 32) pointing from
        /// one packed tile to another — the pathfinder divides this by 32
        /// to get an 8-direction index.
        public static func directionPacked(from: UInt16, to: UInt16) -> UInt8 {
            let returnValues: [UInt8] = [
                0x20, 0x40, 0x20, 0x00, 0xE0, 0xC0, 0xE0, 0x00,
                0x60, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xA0, 0x80
            ]
            let x1 = Int32(from & 0x3F); let y1 = Int32((from >> 6) & 0x3F)
            let x2 = Int32(to & 0x3F);   let y2 = Int32((to >> 6) & 0x3F)

            var index: UInt16 = 0
            var dy = y1 - y2
            if dy < 0 { index |= 0x8; dy = -dy }
            var dx = x2 - x1
            if dx < 0 { index |= 0x4; dx = -dx }

            if dx >= dy {
                if ((dx + 1) / 2) > dy { index |= 0x1 }
            } else {
                index |= 0x2
                if ((dy + 1) / 2) > dx { index |= 0x1 }
            }
            return returnValues[Int(index)]
        }
    }
}
