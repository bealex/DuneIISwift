import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.Map.Generator")
struct MapGeneratorTests {
    @Test("same seed produces identical maps")
    func deterministic() throws {
        let resolver = TileResolver(iconMap: try makeSyntheticLandscapeIconMap())
        let a = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        let b = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        #expect(a.cells == b.cells)
    }

    @Test("different seeds produce different maps")
    func seedsDiffer() throws {
        let resolver = TileResolver(iconMap: try makeSyntheticLandscapeIconMap())
        let a = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        let b = Map.Generator.generate(seed: 0x9999, resolver: resolver)
        #expect(a.cells != b.cells)
    }

    @Test("every tile resolves to a sprite in the LANDSCAPE icon group")
    func tilesInLandscapeRange() throws {
        let iconMap = try makeSyntheticLandscapeIconMap()
        let resolver = TileResolver(iconMap: iconMap)
        let map = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        // The landscape group is 81 entries wide (sprite indices 0..80).
        let lo = resolver.landscapeTileID
        let hi = lo + 80
        for cell in map.cells {
            #expect(cell.groundTileID >= lo)
            #expect(cell.groundTileID <= hi)
        }
    }

    @Test("a typical seed produces all four major terrain types")
    func histogramHasAllTerrain() throws {
        let iconMap = try makeSyntheticLandscapeIconMap()
        let resolver = TileResolver(iconMap: iconMap)
        let map = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        var seen = Set<LandscapeType>()
        for cell in map.cells {
            let lt = resolver.landscapeType(
                groundTileID: cell.groundTileID,
                overlayTileID: 0,
                hasStructure: false
            )
            seen.insert(lt)
        }
        // Sand, dune, rock, mountain, plus at least some spice for this seed.
        #expect(seen.contains(.normalSand))
        #expect(seen.contains(.entirelyRock) || seen.contains(.mostlyRock) || seen.contains(.partialRock))
        #expect(seen.contains(.entirelyMountain) || seen.contains(.partialMountain))
    }

    @Test("seed 0x16BD pins specific sprite indices at known positions")
    func pinnedSeedBaseline() throws {
        let iconMap = try makeSyntheticLandscapeIconMap()
        let resolver = TileResolver(iconMap: iconMap)
        let map = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        let base = resolver.landscapeTileID
        // Sprite index = groundTileID - landscapeTileID (synthetic icon map
        // is identity-mapped so this equality holds exactly).
        let s00 = Int(map[0, 0].groundTileID) - Int(base)
        let s_mid = Int(map[32, 32].groundTileID) - Int(base)
        let s_end = Int(map[63, 63].groundTileID) - Int(base)
        #expect(s00 == pinnedSeed16BD_00)
        #expect(s_mid == pinnedSeed16BD_3232)
        #expect(s_end == pinnedSeed16BD_6363)
    }

    @Test("seed 0x16BD pins a checksum over the full grid")
    func pinnedSeedChecksum() throws {
        let iconMap = try makeSyntheticLandscapeIconMap()
        let resolver = TileResolver(iconMap: iconMap)
        let map = Map.Generator.generate(seed: 0x16BD, resolver: resolver)
        let base = Int(resolver.landscapeTileID)
        var sum = 0
        for cell in map.cells { sum += Int(cell.groundTileID) - base }
        #expect(sum == pinnedSeed16BD_spriteSum)
    }

    // MARK: - Helpers

    /// IconMap with the LANDSCAPE group (group 9) holding 81 consecutive
    /// tile IDs starting at 1000. Other groups are stubbed minimally so
    /// `TileResolver` can initialise. Identity-mapped so `tileId(.landscape, n) == 1000 + n`.
    private func makeSyntheticLandscapeIconMap() throws -> Formats.IconMap {
        // Header: 28 u16 group-start indices, then a sentinel.
        var u16s: [UInt16] = Array(repeating: 28, count: 28)
        u16s[6] = 28   // WALLS: 28..59 (32 entries)
        u16s[7] = 60   // FOG_OF_WAR: 60..91 (32 entries)
        u16s[8] = 92   // CONCRETE_SLAB: 92..123 (32 entries)
        u16s[9] = 124  // LANDSCAPE: 124..204 (81 entries — exactly what the generator needs)
        u16s[10] = 205 // SPICE_BLOOM: 205..236 (32 entries)
        for i in 11..<27 { u16s[i] = 237 }
        u16s[27] = 237

        func run(_ startId: UInt16, _ count: Int) -> [UInt16] {
            (0..<count).map { UInt16(Int(startId) + $0) }
        }
        u16s.append(contentsOf: run(4000, 32)) // walls
        u16s.append(contentsOf: run(5000, 32)) // fog
        u16s.append(contentsOf: run(3000, 32)) // slab
        u16s.append(contentsOf: run(1000, 81)) // LANDSCAPE — 81 entries 1000..1080
        u16s.append(contentsOf: run(2000, 32)) // spice bloom

        var data = Data()
        for v in u16s {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        return try Formats.IconMap.decode(data)
    }
}

// MARK: - Pinned baselines (seed 0x16BD, synthetic identity-mapped LANDSCAPE)

/// Sprite index at (0, 0). Captured by running the implementation once
/// after it was line-for-line ported from OpenDUNE `Map_CreateLandscape`.
/// A change here means an algorithmic regression.
private let pinnedSeed16BD_00 = 0
private let pinnedSeed16BD_3232 = 4
private let pinnedSeed16BD_6363 = 0
/// Sum of all 4096 sprite indices for seed 0x16BD.
private let pinnedSeed16BD_spriteSum = 70057
