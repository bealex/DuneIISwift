import DuneIIContracts
import DuneIIWorld

/// The unit pathfinder — a faithful port of OpenDUNE's `Script_Unit_Pathfinder` + `_Connect` +
/// `_Smoothen` (`src/script/unit.c`). Given a start and destination packed tile and the moving unit, it
/// finds a route (a list of 8-direction steps, `0xFF`-terminated) by trying the direct line and, where
/// that's blocked, wall-following clockwise/counter-clockwise then smoothing. Per-tile cost comes from
/// `Unit_GetTileEnterScore` (`tileEnterScore`, the replaceable `UnitPrimitives`).
public struct Pathfinder: Sendable {
    public let primitives: any UnitPrimitives
    public let map: any MapPrimitives
    public let house: any HousePrimitives

    public init(primitives: any UnitPrimitives = DefaultUnitPrimitives(),
                map: any MapPrimitives = DefaultMapPrimitives(),
                house: any HousePrimitives = DefaultHousePrimitives()) {
        self.primitives = primitives
        self.map = map
        self.house = house
    }

    /// Tile-index delta for each of the 8 directions (`s_mapDirection`).
    static let mapDirection: [Int] = [-64, -63, 1, 65, 64, 63, -1, -65]

    /// A found route: `buffer` holds direction steps (0–7) ending in `0xFF`; `routeSize` counts the
    /// steps; `score` is the summed enter cost.
    public struct Data: Equatable {
        public var packed: UInt16
        public var score: Int16
        public var routeSize: Int
        public var buffer: [UInt8]
    }

    private func step(_ packed: UInt16, _ dir: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: Int(packed) &+ Pathfinder.mapDirection[dir & 7])
    }

    /// `Script_Unit_Pathfind_GetScore` (non-enhanced): `Unit_GetTileEnterScore(unit, packed, dir << 5)`,
    /// mapping the structure sentinel `-1` to 256 (blocked).
    private func score(_ packed: UInt16, _ dir: UInt8, _ unit: Unit, _ state: GameState) -> Int16 {
        var res = primitives.tileEnterScore(unit, packed: packed, orient8: UInt16(dir) << 5,
                                            in: state, map: map, house: house)
        if res == -1 { res = 256 }
        return res
    }

    /// `Script_Unit_Pathfinder` — the entry point.
    public func pathfind(src: UInt16, dst: UInt16, unit: Unit, bufferSize: Int, in state: GameState) -> Data {
        var res = Data(packed: src, score: 0, routeSize: 0, buffer: [UInt8](repeating: 0xFF, count: bufferSize + 2))
        let limit = bufferSize - 1
        var packedCur = src

        while res.routeSize < limit {
            if packedCur == dst { break }

            // Try going directly toward the destination.
            let direction = UInt8(Tile32.directionPacked(packedCur, dst) / 32)
            var packedNext = step(packedCur, Int(direction))
            let s = score(packedNext, direction, unit, state)

            if s <= 255 {
                res.buffer[res.routeSize] = direction
                res.routeSize += 1
                res.score += s
            } else {
                var foundCCW = false, foundCW = false
                var ccw = Data(packed: packedCur, score: 0, routeSize: 0, buffer: [UInt8](repeating: 0xFF, count: 102))
                var cw = Data(packed: packedCur, score: 0, routeSize: 0, buffer: [UInt8](repeating: 0xFF, count: 102))

                while true {
                    if packedNext == dst { break }
                    // First valid tile on the direct route to dst.
                    let dir = UInt8(Tile32.directionPacked(packedNext, dst) / 32)
                    packedNext = step(packedNext, Int(dir))
                    if score(packedNext, dir, unit, state) > 255 { continue }

                    ccw = Data(packed: packedCur, score: 0, routeSize: 0, buffer: ccw.buffer)
                    foundCCW = connect(packedNext, &ccw, -1, direction, unit, state)
                    cw = Data(packed: packedCur, score: 0, routeSize: 0, buffer: cw.buffer)
                    foundCW = connect(packedNext, &cw, 1, direction, unit, state)
                    if foundCCW || foundCW { break }

                    // Advance along the direct line while tiles stay valid (C do/while: `dir` persists
                    // into the condition).
                    var d2: UInt8 = 0
                    repeat {
                        if packedNext == dst { break }
                        d2 = UInt8(Tile32.directionPacked(packedNext, dst) / 32)
                        packedNext = step(packedNext, Int(d2))
                    } while score(packedNext, d2, unit, state) <= 255
                }

                if foundCCW || foundCW {
                    let best: Data = !foundCW ? ccw : (!foundCCW ? cw : (ccw.score < cw.score ? ccw : cw))
                    let routeSize = min(limit - res.routeSize, best.routeSize)
                    if routeSize <= 0 { break }
                    for i in 0 ..< routeSize { res.buffer[res.routeSize + i] = best.buffer[i] }
                    res.routeSize += routeSize
                    res.score += best.score
                } else {
                    break
                }
            }
            packedCur = packedNext
        }

        if res.routeSize < limit { res.buffer[res.routeSize] = 0xFF; res.routeSize += 1 }
        smoothen(&res, unit, state)
        return res
    }

    /// `Script_Unit_Pathfinder_Connect` — wall-follow from `data.packed` toward `packedDst`.
    private func connect(_ packedDst: UInt16, _ data: inout Data, _ searchDirection: Int,
                         _ directionStart: UInt8, _ unit: Unit, _ state: GameState) -> Bool {
        var packedCur = data.packed
        var bufferSize = 0
        var dirStart = directionStart

        while bufferSize < 100 {
            var direction = dirStart
            var packedNext: UInt16 = 0

            while true {
                direction = UInt8((Int(direction) + searchDirection) & 7)

                if direction & 1 != 0 && step(packedCur, (Int(direction) + searchDirection) & 7) == packedDst {
                    direction = UInt8((Int(direction) + searchDirection) & 7)
                    packedNext = step(packedCur, Int(direction))
                    break
                } else {
                    if direction == dirStart { return false }
                    packedNext = step(packedCur, Int(direction))
                    if score(packedNext, direction, unit, state) <= 255 { break }
                }
            }

            data.buffer[bufferSize] = direction
            bufferSize += 1

            if packedNext == packedDst {
                data.buffer[bufferSize] = 0xFF
                data.routeSize = bufferSize
                smoothen(&data, unit, state)
                data.routeSize -= 1
                return true
            }
            if data.packed == packedNext { return false }

            dirStart = UInt8((Int(direction) - searchDirection * 3) & 7)
            packedCur = packedNext
        }
        return false
    }

    /// `Script_Unit_Pathfinder_Smoothen` — remove redundant direction changes, then compact the route.
    private func smoothen(_ data: inout Data, _ unit: Unit, _ state: GameState) {
        let directionOffset: [Int8] = [0, 0, 1, 2, 3, -2, -1, 0]
        data.buffer[data.routeSize] = 0xFF
        var packed = data.packed

        if data.routeSize > 1 {
            var to = 1
            while data.buffer[to] != 0xFF {
                var from = to - 1
                while data.buffer[from] == 0xFE && from != 0 { from -= 1 }
                if data.buffer[from] == 0xFE { to += 1; continue }

                let diff = Int(Int8(bitPattern: (data.buffer[to] &- data.buffer[from]) & 0x7))
                let direction = directionOffset[Int(UInt8(truncatingIfNeeded: diff)) & 7]

                if direction == 3 {                       // opposite directions — both removable
                    data.buffer[from] = 0xFE
                    data.buffer[to] = 0xFE
                    to += 1
                    continue
                }
                if direction == 0 {                       // same direction — follow
                    packed = step(packed, Int(data.buffer[from]))
                    to += 1
                    continue
                }

                var dir: UInt8
                if data.buffer[from] & 1 != 0 {
                    dir = UInt8((Int(data.buffer[from]) + (direction < 0 ? -1 : 1)) & 7)
                    if abs(Int(direction)) == 1 {         // 45° with a 90° difference — can go straight
                        if score(step(packed, Int(dir)), dir, unit, state) <= 255 {
                            data.buffer[to] = dir
                            data.buffer[from] = dir
                        }
                        packed = step(packed, Int(data.buffer[from]))
                        to += 1
                        continue
                    }
                } else {
                    dir = UInt8((Int(data.buffer[from]) + Int(direction)) & 7)
                }

                // One fewer direction change — replace and walk back a tile.
                data.buffer[to] = dir
                data.buffer[from] = 0xFE
                while data.buffer[from] == 0xFE && from != 0 { from -= 1 }
                if data.buffer[from] != 0xFE {
                    packed = step(packed, (Int(data.buffer[from]) + 4) & 7)
                } else {
                    packed = data.packed
                }
            }
        }

        // Rebuild the compacted route (no 0xFE gaps), re-scoring.
        var from = 0
        var to = 0
        packed = data.packed
        data.score = 0
        data.routeSize = 0
        while data.buffer[to] != 0xFF {
            if data.buffer[to] == 0xFE { to += 1; continue }
            packed = step(packed, Int(data.buffer[to]))
            data.score += score(packed, data.buffer[to], unit, state)
            data.routeSize += 1
            data.buffer[from] = data.buffer[to]
            from += 1
            to += 1
        }
        data.routeSize += 1
        data.buffer[from] = 0xFF
    }
}
