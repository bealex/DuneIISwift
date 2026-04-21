import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.IconMap")
struct IconMapTests {
    /// Builds a minimal three-group IconMap with known tile IDs, using only
    /// three of the 28 real groups — the rest point at an empty sentinel.
    /// Layout (all u16 LE), where H = header size in bytes = 28 * 2 = 56:
    ///   index[0]    = 28            -> ROCK_CRATERS starts at u16 index 28 (the tile data)
    ///   index[1..5] = 28            -> empty groups (start == end)
    ///   index[6]    = 28            -> WALLS (our test group)
    ///   index[7]    = 31            -> FOG_OF_WAR
    ///   index[8]    = 34            -> CONCRETE_SLAB
    ///   index[9..26]= 37            -> empty
    ///   index[27]   = 37            -> EOF sentinel
    ///   tiles[28..30] = walls [100, 101, 102]
    ///   tiles[31..33] = fog   [200, 201, 202]
    ///   tiles[34..36] = slab  [300, 301, 302]
    private static func buildSynthetic() -> Data {
        var u16s: [UInt16] = Array(repeating: 28, count: 28)
        u16s[6] = 28  // walls
        u16s[7] = 31  // fog
        u16s[8] = 34  // concrete slab
        for i in 9..<27 { u16s[i] = 37 }
        u16s[27] = 37 // sentinel

        u16s.append(contentsOf: [100, 101, 102]) // walls
        u16s.append(contentsOf: [200, 201, 202]) // fog
        u16s.append(contentsOf: [300, 301, 302]) // slab

        var data = Data()
        data.reserveCapacity(u16s.count * 2)
        for v in u16s {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        return data
    }

    @Test("group tile-id slice matches synthetic layout")
    func groupTileIdSlice() throws {
        let map = try Formats.IconMap.decode(Self.buildSynthetic())
        #expect(map.tileIds(in: .walls) == [100, 101, 102])
        #expect(map.tileIds(in: .fogOfWar) == [200, 201, 202])
        #expect(map.tileIds(in: .concreteSlab) == [300, 301, 302])
    }

    @Test("tileId(in:offset:) matches OpenDUNE's double indirection")
    func openduneIndexing() throws {
        let map = try Formats.IconMap.decode(Self.buildSynthetic())
        // The idiom `map[map[group] + k]`: for walls with offset 2 we expect
        // the third tile ID in the walls run, which is 102.
        #expect(map.tileId(in: .walls, offset: 2) == 102)
        #expect(map.tileId(in: .fogOfWar, offset: 1) == 201)
    }

    @Test("empty groups return an empty slice")
    func emptyGroup() throws {
        let map = try Formats.IconMap.decode(Self.buildSynthetic())
        #expect(map.tileIds(in: .rockCraters).isEmpty)
        #expect(map.tileIds(in: .sandTracks).isEmpty)
    }

    @Test("truncated file is rejected")
    func truncated() {
        // One byte short of even a single u16.
        let data = Data([0x01])
        #expect(throws: Formats.IconMap.DecodeError.self) {
            _ = try Formats.IconMap.decode(data)
        }
    }

    @Test("header too small is rejected")
    func headerTooSmall() {
        // Only 10 u16s — below the 28-entry group header.
        let data = Data(repeating: 0, count: 20)
        #expect(throws: Formats.IconMap.DecodeError.self) {
            _ = try Formats.IconMap.decode(data)
        }
    }

    @Test("real ICON.MAP decodes and points FOG_OF_WAR + 16 at a valid tile")
    func realIconMap() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "ICON.MAP") else { return }
        let map = try Formats.IconMap.decode(body)
        #expect(map.groupCount == 28)
        let veiled = map.tileId(in: .fogOfWar, offset: 16)
        #expect(veiled > 0)
    }
}
