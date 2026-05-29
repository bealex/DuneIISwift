import DuneIIContracts
import DuneIIFormats

public extension GameState {
    /// `Map_CreateLandscape` (`src/map.c`): generate the base landscape into `map` from `seed`. A
    /// faithful, RNG-exact port — it reseeds the game RNG to `seed` and draws the whole map from it, so
    /// the same seed yields byte-identical terrain to OpenDUNE. `iconMap` supplies the landscape icon
    /// group for the final sprite mapping (`g_iconMap[g_iconMap[LANDSCAPE] + spriteIndex]`).
    mutating func createLandscape(seed: UInt32, iconMap: IconMap) {
        let around = [0, -1, 1, -16, 16, -17, 17, -15, 15, -2, 2, -32, 32, -4, 4, -64, 64, -30, 30, -34, 34]
        // _offsetTable[2][21][4]; the two rows differ only at index 12.
        let offsetTable: [[[Int]]] = [
            [[0,0,4,0],[4,0,4,4],[0,0,0,4],[0,4,4,4],[0,0,0,2],[0,2,0,4],[0,0,2,0],[2,0,4,0],[4,0,4,2],
             [4,2,4,4],[0,4,2,4],[2,4,4,4],[0,0,4,4],[2,0,2,2],[0,0,2,2],[4,0,2,2],[0,2,2,2],[2,2,4,2],
             [2,2,0,4],[2,2,4,4],[2,2,2,4]],
            [[0,0,4,0],[4,0,4,4],[0,0,0,4],[0,4,4,4],[0,0,0,2],[0,2,0,4],[0,0,2,0],[2,0,4,0],[4,0,4,2],
             [4,2,4,4],[0,4,2,4],[2,4,4,4],[4,0,0,4],[2,0,2,2],[0,0,2,2],[4,0,2,2],[0,2,2,2],[2,2,4,2],
             [2,2,0,4],[2,2,4,4],[2,2,2,4]],
        ]
        let sand = UInt16(LandscapeType.normalSand.rawValue)        // 0
        let dune = UInt16(LandscapeType.entirelyDune.rawValue)      // 2
        let rock = UInt16(LandscapeType.entirelyRock.rawValue)      // 4
        let mountain = UInt16(LandscapeType.entirelyMountain.rawValue) // 6

        random256.reseed(seed)

        // Place random data on a 4×4 grid.
        var memory = [UInt8](repeating: 0, count: 273)
        for i in 0 ..< 272 {
            var m = random256.next() & 0xF
            if m > 0xA { m = 0xA }
            memory[i] = m
        }
        var iterations = Int(random256.next() & 0xF) + 1
        while iterations > 0 {
            iterations -= 1
            let base = Int(random256.next())
            for j in 0 ..< around.count {
                let index = min(max(0, base + around[j]), 272)
                memory[index] = (memory[index] &+ (random256.next() & 0xF)) & 0xF
            }
        }
        iterations = Int(random256.next() & 0x3) + 1
        while iterations > 0 {
            iterations -= 1
            let base = Int(random256.next())
            for j in 0 ..< around.count {
                let index = min(max(0, base + around[j]), 272)
                memory[index] = random256.next() & 0x3
            }
        }
        for j in 0 ..< 16 {
            for i in 0 ..< 16 {
                map[Int(Tile32.packXY(x: UInt16(i * 4), y: UInt16(j * 4)))].groundTileID = UInt16(memory[j * 16 + i])
            }
        }

        // Average around the 4×4 grid.
        for j in 0 ..< 16 {
            for i in 0 ..< 16 {
                for k in 0 ..< 21 {
                    let o = offsetTable[(i + 1) % 2][k]
                    let p1 = Int(Tile32.packXY(x: UInt16(i * 4 + o[0]), y: UInt16(j * 4 + o[1])))
                    let p2 = Int(Tile32.packXY(x: UInt16(i * 4 + o[2]), y: UInt16(j * 4 + o[3])))
                    let packed = (p1 + p2) / 2
                    if Tile32.isOutOfMap(UInt16(packed)) { continue }
                    let packed1 = Int(Tile32.packXY(x: UInt16((i * 4 + o[0]) & 0x3F), y: UInt16(j * 4 + o[1])))
                    let packed2 = Int(Tile32.packXY(x: UInt16((i * 4 + o[2]) & 0x3F), y: UInt16(j * 4 + o[3])))
                    let sprite2 = packed2 < 64 * 64 ? Int(map[packed2].groundTileID) : 0
                    map[packed].groundTileID = UInt16((Int(map[packed1].groundTileID) + sprite2 + 1) / 2)
                }
            }
        }

        // Average each tile with its (up to 8) neighbours.
        var currentRow = [UInt16](repeating: 0, count: 64)
        var previousRow = [UInt16](repeating: 0, count: 64)
        for j in 0 ..< 64 {
            let row = j * 64
            previousRow = currentRow
            for i in 0 ..< 64 { currentRow[i] = map[row + i].groundTileID }
            for i in 0 ..< 64 {
                let cur = currentRow[i]
                var total = Int(cur)
                total += Int((i == 0 || j == 0) ? cur : previousRow[i - 1])
                total += Int((j == 0) ? cur : previousRow[i])
                total += Int((i == 63 || j == 0) ? cur : previousRow[i + 1])
                total += Int((i == 0) ? cur : currentRow[i - 1])
                total += Int((i == 63) ? cur : currentRow[i + 1])
                total += Int((i == 0 || j == 63) ? cur : map[row + i + 63].groundTileID)
                total += Int((j == 63) ? cur : map[row + i + 64].groundTileID)
                total += Int((i == 63 || j == 63) ? cur : map[row + i + 65].groundTileID)
                map[row + i].groundTileID = UInt16(total / 9)
            }
        }

        // Filter each tile into a landscape type.
        var spriteID1 = UInt16(random256.next() & 0xF)
        if spriteID1 < 0x8 { spriteID1 = 0x8 }
        if spriteID1 > 0xC { spriteID1 = 0xC }
        var spriteID2 = UInt16(random256.next() & 0x3) &- 1     // wraps to 0xFFFF when the draw is 0
        if spriteID2 > spriteID1 &- 3 { spriteID2 = spriteID1 &- 3 }
        for i in 0 ..< 4096 {
            let s = map[i].groundTileID
            if s > spriteID1 + 4 { map[i].groundTileID = mountain }
            else if s >= spriteID1 { map[i].groundTileID = rock }
            else if s <= spriteID2 { map[i].groundTileID = dune }
            else { map[i].groundTileID = sand }
        }

        // Add some spice.
        var blobs = Int(random256.next() & 0x2F)
        while blobs > 0 {
            blobs -= 1
            var packed = 0
            while true {
                let y = UInt16(random256.next() & 0x3F)
                packed = Int(Tile32.packXY(x: UInt16(random256.next() & 0x3F), y: y))
                if canBecomeSpice(map[packed].groundTileID) { break }
            }
            let tile = Tile32.unpack(UInt16(packed))
            var spots = Int(random256.next() & 0x1F)
            while spots > 0 {
                spots -= 1
                var p = 0
                while true {
                    let moved = Tile32.moveByRandom(tile, distance: UInt16(random256.next() & 0x3F),
                                                    center: true, rng: &random256)
                    p = Int(moved.packed)
                    if !Tile32.isOutOfMap(UInt16(p)) { break }
                }
                addSpiceOnTile(UInt16(p))
            }
        }

        // Smooth + pick the final sprite index, then map it through the landscape icon group.
        for j in 0 ..< 64 {
            let row = j * 64
            previousRow = currentRow
            for i in 0 ..< 64 { currentRow[i] = map[row + i].groundTileID }
            for i in 0 ..< 64 {
                let current = currentRow[i]
                let up = (j == 0) ? current : previousRow[i]
                let right = (i == 63) ? current : currentRow[i + 1]
                let down = (j == 63) ? current : map[row + i + 64].groundTileID
                let left = (i == 0) ? current : currentRow[i - 1]
                var spriteID: UInt16 = 0
                if up == current { spriteID |= 1 }
                if right == current { spriteID |= 2 }
                if down == current { spriteID |= 4 }
                if left == current { spriteID |= 8 }
                let thickSpice = UInt16(LandscapeType.thickSpice.rawValue)
                switch current {
                    case sand: spriteID = 0
                    case rock:
                        if up == mountain { spriteID |= 1 }
                        if right == mountain { spriteID |= 2 }
                        if down == mountain { spriteID |= 4 }
                        if left == mountain { spriteID |= 8 }
                        spriteID += 1
                    case dune: spriteID += 17
                    case mountain: spriteID += 33
                    case UInt16(LandscapeType.spice.rawValue):
                        if up == thickSpice { spriteID |= 1 }
                        if right == thickSpice { spriteID |= 2 }
                        if down == thickSpice { spriteID |= 4 }
                        if left == thickSpice { spriteID |= 8 }
                        spriteID += 49
                    case thickSpice: spriteID += 65
                    default: break
                }
                map[row + i].groundTileID = spriteID
            }
        }

        // Finalise with the real sprite IDs from the landscape icon group (ICM_ICONGROUP_LANDSCAPE = 9).
        for i in 0 ..< 4096 {
            let spriteIndex = Int(map[i].groundTileID)
            map[i].groundTileID = UInt16(iconMap.tileID(group: 9, offset: spriteIndex) ?? 0)
            map[i].overlayTileID = UInt8(truncatingIfNeeded: tileIDs.veiled)
            map[i].houseID = UInt8(HouseID.harkonnen.rawValue)
            map[i].isUnveiled = false
            map[i].hasUnit = false
            map[i].hasStructure = false
            map[i].hasAnimation = false
            map[i].hasExplosion = false
        }
    }

    /// `Map_AddSpiceOnTile` (`src/map.c`): grow spice at `packed` (sand → spice → thick spice, with the
    /// thick-spice ring constrained by which neighbours can hold spice).
    private mutating func addSpiceOnTile(_ packed: UInt16) {
        let p = Int(packed)
        let spice = UInt16(LandscapeType.spice.rawValue)
        let thick = UInt16(LandscapeType.thickSpice.rawValue)

        switch map[p].groundTileID {
            case spice:
                map[p].groundTileID = thick
                addSpiceOnTile(packed)
            case thick:
                for j in -1 ... 1 {
                    for i in -1 ... 1 {
                        let packed2 = Tile32.packXY(
                            x: UInt16(truncatingIfNeeded: Int(Tile32.packedX(packed)) + i),
                            y: UInt16(truncatingIfNeeded: Int(Tile32.packedY(packed)) + j))
                        if Tile32.isOutOfMap(packed2) { continue }
                        let p2 = Int(packed2)
                        if !canBecomeSpice(map[p2].groundTileID) {
                            map[p].groundTileID = spice
                            continue
                        }
                        if map[p2].groundTileID != thick { map[p2].groundTileID = spice }
                    }
                }
            default:
                if canBecomeSpice(map[p].groundTileID) { map[p].groundTileID = spice }
        }
    }

    /// `g_table_landscapeInfo[id].canBecomeSpice` with an out-of-range guard.
    private func canBecomeSpice(_ id: UInt16) -> Bool {
        guard let type = LandscapeType(rawValue: Int(id)) else { return false }
        return LandscapeInfo[type].canBecomeSpice
    }
}
