import Foundation
import Testing
@testable import DuneIIFormats

@Suite("IconMap")
struct IconMapTests {
    // count=3 (groups 1,2 + EOF); group1 offset=4 -> tiles[100,101]; group2 offset=6 -> tiles[200,201,202].
    static let synthetic = Data([
        0x03, 0x00,   // [0] count = 3
        0x04, 0x00,   // [1] group 1 offset = 4
        0x06, 0x00,   // [2] group 2 offset = 6
        0x00, 0x00,   // [3] EOF (0)
        0x64, 0x00,   // [4] = 100
        0x65, 0x00,   // [5] = 101
        0xC8, 0x00,   // [6] = 200
        0xC9, 0x00,   // [7] = 201
        0xCA, 0x00,   // [8] = 202
    ])

    @Test("parses icon groups and their tile-ID lists")
    func groups() throws {
        let map = try IconMap(IconMapTests.synthetic)
        let groups = map.groups
        #expect(groups.count == 2)
        #expect(groups[0].tileIDs == [ 100, 101 ])
        #expect(groups[1].tileIDs == [ 200, 201, 202 ])
        #expect(IconMap.name(1) == "Rock Craters")
        #expect(IconMap.name(19) == "Windtrap")
    }

    @Test("tileID does the flat g_iconMap[g_iconMap[group]+offset] lookup (across group bounds)")
    func flatTileID() throws {
        let map = try IconMap(IconMapTests.synthetic)
        #expect(map.tileID(group: 1, offset: 0) == 100)
        #expect(map.tileID(group: 2, offset: 2) == 202)
        #expect(map.tileID(group: 1, offset: 2) == 200)   // past group 1's tiles into group 2's data
        #expect(map.tileID(group: 9, offset: 0) == nil)    // group out of range
        #expect(map.tileID(group: 2, offset: 99) == nil)   // offset out of range
    }

    @Test("real install ICON.MAP groups reference valid ICON.ICN tiles")
    func realData() throws {
        guard
            let mapData = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: "ICON.MAP"),
            let icnData = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: "ICON.ICN")
        else { return }

        let map = try IconMap(mapData)
        let tiles = try Icn.TileSet(icnData)
        #expect(!map.groups.isEmpty)
        #expect(map.groups.contains { $0.index == 19 && $0.name == "Windtrap" && !$0.tileIDs.isEmpty })
        for group in map.groups {
            #expect(group.tileIDs.allSatisfy { $0 >= 0 && $0 < tiles.tileCount })
        }
    }
}
