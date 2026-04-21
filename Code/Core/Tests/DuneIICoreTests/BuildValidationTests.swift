import Foundation
import Testing
@testable import DuneIICore

@Suite("Build validation — sortPriority + footprint helpers + IsValidBuildLocation (slice 4a)")
struct BuildValidationTests {

    private let SLAB_1x1: UInt8 = 0
    private let LIGHT_VEHICLE: UInt8 = 3
    private let WINDTRAP: UInt8 = 9
    private let REFINERY: UInt8 = 12
    private let SILO: UInt8 = 17

    // MARK: StructureInfo.sortPriority field

    @Test("sortPriority matches OpenDUNE's src/table/structureinfo.c for every type")
    func sortPriorityTable() {
        let expected: [UInt16] = [
            2,   // 0 SLAB_1x1
            4,   // 1 SLAB_2x2
            5,   // 2 PALACE
            14,  // 3 LIGHT_VEHICLE
            28,  // 4 HEAVY_VEHICLE
            30,  // 5 HIGH_TECH
            34,  // 6 HOUSE_OF_IX
            20,  // 7 WOR_TROOPER
            0,   // 8 CONSTRUCTION_YARD
            6,   // 9 WINDTRAP
            18,  // 10 BARRACKS
            32,  // 11 STARPORT
            8,   // 12 REFINERY
            24,  // 13 REPAIR
            16,  // 14 WALL
            22,  // 15 TURRET
            26,  // 16 ROCKET_TURRET
            12,  // 17 SILO
            10   // 18 OUTPOST
        ]
        for i in 0..<19 {
            #expect(Simulation.StructureInfo.table[i].sortPriority == expected[i])
        }
    }

    // MARK: buildableTypesByPriority

    @Test("buildableTypesByPriority on empty bitmask → []")
    func priorityEmpty() {
        #expect(Simulation.StructureInfo.buildableTypesByPriority(from: 0) == [])
    }

    @Test("buildableTypesByPriority of (SLAB_1x1 + WINDTRAP) → [0, 9] (already ascending)")
    func prioritySimple() {
        let mask: UInt32 = (1 << 0) | (1 << 9)
        #expect(Simulation.StructureInfo.buildableTypesByPriority(from: mask) == [0, 9])
    }

    @Test("buildableTypesByPriority differs from ascending type-ID when priorities re-order")
    func priorityReorders() {
        // LIGHT_VEHICLE (type 3, priority 14) + SILO (type 17, priority 12).
        // Ascending type-ID would give [3, 17]; priority order gives [17, 3].
        let mask: UInt32 = (1 << Int(LIGHT_VEHICLE)) | (1 << Int(SILO))
        #expect(Simulation.StructureInfo.buildableTypesByPriority(from: mask) == [17, 3])
    }

    @Test("buildableTypesByPriority over all 19 types matches OpenDUNE priority order")
    func priorityFull() {
        let mask: UInt32 = 0x0007_FFFF
        // CYARD(0) first, then slab(2), slab2(4), palace(5), windtrap(6),
        // refinery(8), outpost(10), silo(12), light(14), wall(16),
        // barracks(18), wor(20), turret(22), repair(24), r-turret(26),
        // heavy(28), hi-tech(30), starport(32), IX(34).
        let expected: [UInt8] = [8, 0, 1, 2, 9, 12, 18, 17, 3, 14, 10, 7, 15, 13, 16, 4, 5, 11, 6]
        #expect(Simulation.StructureInfo.buildableTypesByPriority(from: mask) == expected)
    }

    // MARK: StructureLayout.footprintOffsets

    @Test("layout s1x1 covers 1 tile at (0,0)")
    func layoutS1x1() {
        let o = Simulation.StructureLayout.s1x1.footprintOffsets
        #expect(o.count == 1)
        #expect(o[0] == (0, 0))
    }

    @Test("layout s2x2 covers 4 tiles")
    func layoutS2x2() {
        let o = Simulation.StructureLayout.s2x2.footprintOffsets
        #expect(o.count == 4)
        let set = Set(o.map { "\($0.x),\($0.y)" })
        #expect(set == ["0,0", "1,0", "0,1", "1,1"])
    }

    @Test("layout s3x3 covers 9 tiles")
    func layoutS3x3() {
        let o = Simulation.StructureLayout.s3x3.footprintOffsets
        #expect(o.count == 9)
    }

    // MARK: Structures.footprintTiles

    @Test("footprintTiles WINDTRAP (s2x2) at (5,5) → 4 consecutive tiles")
    func footprintWindtrap() {
        let tiles = Simulation.Structures.footprintTiles(type: WINDTRAP, anchorX: 5, anchorY: 5)
        let set = Set(tiles.map { "\($0.x),\($0.y)" })
        #expect(set == ["5,5", "6,5", "5,6", "6,6"])
    }

    @Test("footprintTiles REFINERY (s3x2) at (10,10) → 6 tiles spanning (10,10)..(12,11)")
    func footprintRefinery() {
        let tiles = Simulation.Structures.footprintTiles(type: REFINERY, anchorX: 10, anchorY: 10)
        let set = Set(tiles.map { "\($0.x),\($0.y)" })
        #expect(set == ["10,10", "11,10", "12,10", "10,11", "11,11", "12,11"])
    }

    @Test("footprintTiles passes through negative anchor unchanged (bounds-check is isValid's job)")
    func footprintNegativeAnchor() {
        let tiles = Simulation.Structures.footprintTiles(type: SLAB_1x1, anchorX: -1, anchorY: 0)
        #expect(tiles[0] == (-1, 0))
    }

    // MARK: Structures.isValidBuildLocation

    @Test("empty pools + in-bounds WINDTRAP → 1")
    func validEmptyPool() {
        let structures = Simulation.StructurePool()
        let units = Simulation.UnitPool()
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: structures, units: units
        )
        #expect(r == 1)
    }

    @Test("WINDTRAP at (63,63) goes out of bounds in east/south → 0")
    func invalidOutOfBoundsEast() {
        let structures = Simulation.StructurePool()
        let units = Simulation.UnitPool()
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 63, tileY: 63, type: WINDTRAP,
            structures: structures, units: units
        )
        #expect(r == 0)
    }

    @Test("SLAB_1x1 at (-1, 0) → 0 (negative anchor)")
    func invalidNegativeAnchor() {
        let structures = Simulation.StructurePool()
        let units = Simulation.UnitPool()
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: -1, tileY: 0, type: SLAB_1x1,
            structures: structures, units: units
        )
        #expect(r == 0)
    }

    @Test("existing WINDTRAP at (5,5); REFINERY anchor at (4,4) overlaps → 0")
    func invalidStructureOverlap() {
        var structures = Simulation.StructurePool()
        let units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        // REFINERY is s3x2; anchor (4,4) covers (4..6, 4..5), overlapping WINDTRAP's (5,5).
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 4, tileY: 4, type: REFINERY,
            structures: structures, units: units
        )
        #expect(r == 0)
    }

    @Test("existing WINDTRAP at (5,5); REFINERY anchor at (10,10) does NOT overlap → 1")
    func validNonOverlapping() {
        var structures = Simulation.StructurePool()
        let units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 10, tileY: 10, type: REFINERY,
            structures: structures, units: units
        )
        #expect(r == 1)
    }

    @Test("unit on tile (5,5); SLAB_1x1 at (5,5) → 0")
    func invalidUnitOverlap() {
        let structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        // Allocate a unit and set position to tile (5, 5) — pos32 = tile * 256.
        units.allocate(at: 0, type: 1, houseID: Simulation.House.atreides)
        var unit = units[0]
        unit.positionX = 5 * 256
        unit.positionY = 5 * 256
        units[0] = unit
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: SLAB_1x1,
            structures: structures, units: units
        )
        #expect(r == 0)
    }

    @Test("unit on a tile not in the footprint → 1")
    func validUnitOutsideFootprint() {
        let structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 1, houseID: Simulation.House.atreides)
        var unit = units[0]
        unit.positionX = 10 * 256  // tile (10, 10)
        unit.positionY = 10 * 256
        units[0] = unit
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: SLAB_1x1,
            structures: structures, units: units
        )
        #expect(r == 1)
    }

    // MARK: Slice 4b — landscape gate + slab count + notOnConcrete

    @Test("LandscapeInfo carries isValidForStructure2 matching OpenDUNE (rock-family only)")
    func landscapeIsValidForStructure2Table() {
        // Only LST_ENTIRELY_ROCK (4), LST_MOSTLY_ROCK (5), LST_DESTROYED_WALL (13)
        // should return isValidForStructure2 == true.
        let expectedTrue: Set<Int> = [4, 5, 13]
        for i in 0..<15 {
            let info = Simulation.LandscapeInfo.table[i]
            if expectedTrue.contains(i) {
                #expect(info.isValidForStructure2, "LST[\(i)] expected isValidForStructure2=true")
            } else {
                #expect(!info.isValidForStructure2, "LST[\(i)] expected isValidForStructure2=false")
            }
        }
    }

    @Test("LandscapeInfo mostly-rock + destroyed-wall are validForStructure (OpenDUNE parity)")
    func landscapeRockFixes() {
        #expect(Simulation.LandscapeInfo.table[5].isValidForStructure)    // MOSTLY_ROCK
        #expect(Simulation.LandscapeInfo.table[13].isValidForStructure)   // DESTROYED_WALL
    }

    @Test("StructureInfo.notOnConcrete is true only for CONSTRUCTION_YARD (type 8)")
    func notOnConcreteCYOnly() {
        for i in 0..<19 {
            let info = Simulation.StructureInfo.table[i]
            if i == 8 {
                #expect(info.notOnConcrete, "CONSTRUCTION_YARD should be notOnConcrete=true")
            } else {
                #expect(!info.notOnConcrete, "type \(i) should be notOnConcrete=false")
            }
        }
    }

    @Test("landscape gate: WINDTRAP on all-sand rejects (0)")
    func landscapeGateSand() {
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .normalSand }
        )
        #expect(r == 0)
    }

    @Test("landscape gate: WINDTRAP on all-rock returns -neededSlabs (4 tiles, no concrete → -4)")
    func landscapeGateRockAllSlabNeeded() {
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock }
        )
        #expect(r == -4)
    }

    @Test("landscape gate: WINDTRAP on full concrete slab returns 1 (all slabs present)")
    func landscapeGateConcrete() {
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .concreteSlab }
        )
        #expect(r == 1)
    }

    @Test("landscape gate: WINDTRAP on 2 concrete + 2 rock returns -2")
    func landscapeGateMixed() {
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { x, _ in
                // x=5 → rock, x=6 → concrete. Footprint covers x∈{5, 6}.
                x == 5 ? .entirelyRock : .concreteSlab
            }
        )
        #expect(r == -2)
    }

    @Test("landscape gate: sand under any non-CY structure → invalid (partial footprint on sand also fails)")
    func landscapeGatePartialSand() {
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { x, _ in
                // Three rock tiles + one sand tile at (6, 5) corner.
                x == 6 ? .normalSand : .entirelyRock
            }
        )
        #expect(r == 0)
    }

    @Test("landscape gate: CONSTRUCTION_YARD on rock valid; on sand / concrete invalid (notOnConcrete quirk)")
    func landscapeGateConstructionYard() {
        let CYARD: UInt8 = 8
        let rock = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: CYARD,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock }
        )
        #expect(rock == 1)
        let sand = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: CYARD,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .normalSand }
        )
        #expect(sand == 0)
        // OpenDUNE quirk: CONCRETE_SLAB fails isValidForStructure2 → CY can't sit there.
        let concrete = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: CYARD,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .concreteSlab }
        )
        #expect(concrete == 0)
    }

    @Test("landscapeAt = nil preserves slice-4a semantics — no landscape check")
    func landscapeAtNilPreservesSlice4a() {
        // With nil, WINDTRAP on an implicit-sand world should still return 1
        // (no overlap, in-bounds). Slice-4a tests already cover this, but
        // explicitly re-assert here so the nil path is pinned.
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: nil
        )
        #expect(r == 1)
    }

    // MARK: Slice 4c — layoutTilesAround + adjacency gate

    @Test("layout s1x1 adjacentOffsets has exactly 8 entries (8-neighbourhood)")
    func adjacentS1x1() {
        let o = Simulation.StructureLayout.s1x1.adjacentOffsets
        #expect(o.count == 8)
        let set = Set(o.map { "\($0.x),\($0.y)" })
        #expect(set == [
            "0,-1", "1,-1", "1,0", "1,1", "0,1", "-1,1", "-1,0", "-1,-1"
        ])
    }

    @Test("layout s3x3 adjacentOffsets has exactly 16 entries around the 3x3 ring")
    func adjacentS3x3() {
        let o = Simulation.StructureLayout.s3x3.adjacentOffsets
        #expect(o.count == 16)
    }

    @Test("adjacency: no existing player structure → WINDTRAP invalid on rock")
    func adjacencyNoBaseInvalid() {
        // Rock everywhere, no player structures, player yard placement attempt.
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 5, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock },
            playerHouseID: Simulation.House.atreides,
            tileHouseIDAt: { _, _ in 0 }
        )
        #expect(r == 0)
    }

    @Test("adjacency: player-owned windtrap at (5,5); new windtrap at (7,5) → valid (east edge adjacent)")
    func adjacencyPlayerWindtrapAdjacent() {
        var structures = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        // WINDTRAP at (7,5) covers (7..8, 5..6). The existing (5..6, 5..6)
        // touches via tile (6,5) being in the adjacency ring of (7,5).
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 7, tileY: 5, type: WINDTRAP,
            structures: structures,
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock },
            playerHouseID: Simulation.House.atreides,
            tileHouseIDAt: { _, _ in 0 }
        )
        // slab count = 4 rock tiles → -4 (valid, degraded).
        #expect(r == -4)
    }

    @Test("adjacency: player-owned windtrap at (5,5); new windtrap at (20,20) not adjacent → invalid")
    func adjacencyTooFar() {
        var structures = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 20, tileY: 20, type: WINDTRAP,
            structures: structures,
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock },
            playerHouseID: Simulation.House.atreides,
            tileHouseIDAt: { _, _ in 0 }
        )
        #expect(r == 0)
    }

    @Test("adjacency: enemy structure adjacent does NOT satisfy player adjacency")
    func adjacencyEnemyDoesntCount() {
        var structures = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: Simulation.House.harkonnen,  // enemy
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 7, tileY: 5, type: WINDTRAP,
            structures: structures,
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock },
            playerHouseID: Simulation.House.atreides,
            tileHouseIDAt: { _, _ in 0 }
        )
        #expect(r == 0)
    }

    @Test("adjacency: concrete slab adjacent + player-owned tileHouseID satisfies adjacency")
    func adjacencyPlayerSlabFallback() {
        // No pool structures, but a concrete slab at (6,5) owned by player.
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 7, tileY: 5, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { x, y in
                x == 6 && y == 5 ? .concreteSlab : .entirelyRock
            },
            playerHouseID: Simulation.House.atreides,
            tileHouseIDAt: { x, y in
                x == 6 && y == 5 ? Simulation.House.atreides : 0
            }
        )
        // slab count = 4 rock tiles (WINDTRAP footprint is 7..8 × 5..6, all rock)
        #expect(r == -4)
    }

    @Test("adjacency: CONSTRUCTION_YARD placement skips the adjacency gate")
    func adjacencyCYSkipsGate() {
        let CYARD: UInt8 = 8
        // Rock everywhere, no player base, no adjacent player anything.
        // CY placement should still succeed (the gate only applies to non-CY).
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 20, tileY: 20, type: CYARD,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock },
            playerHouseID: Simulation.House.atreides,
            tileHouseIDAt: { _, _ in 0 }
        )
        #expect(r == 1)
    }

    @Test("playerHouseID = nil preserves slice-4b semantics — no adjacency check")
    func playerHouseIDNilPreservesSlice4b() {
        // Rock everywhere, no base, WINDTRAP — with playerHouseID=nil, no
        // adjacency gate runs; returns -4 for the slab deficit.
        let r = Simulation.Structures.isValidBuildLocation(
            tileX: 20, tileY: 20, type: WINDTRAP,
            structures: Simulation.StructurePool(),
            units: Simulation.UnitPool(),
            landscapeAt: { _, _ in .entirelyRock },
            playerHouseID: nil
        )
        #expect(r == -4)
    }
}
