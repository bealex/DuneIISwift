import Foundation
import Testing
import DuneIIFormats
@testable import DuneIIWorld

/// `TileIDs` (sprite tile-id init, a port of `Sprites_Init`) derived from the committed real
/// `ICON.MAP`. The expected bases were computed from the raw `ICON.MAP` via the OpenDUNE formula
/// `g_iconMap[g_iconMap[ICM_ICONGROUP_X] + offset]`; the `IconMap` decoder is itself real-data-tested.
@Suite("Sprite tile-id init")
struct TileIDsTests {
    @Test("TileIDs derived from the real ICON.MAP match Sprites_Init")
    func fromIconMap() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }   // Code/Tests/WorldTests/ → repo root
        url.appendPathComponent("Resources/Tiles/Maps/ICON.MAP")

        let iconMap = try IconMap(Data(contentsOf: url))
        let ids = try #require(TileIDs(iconMap: iconMap))

        #expect(ids.veiled == 124)
        #expect(ids.bloom == 208)
        #expect(ids.builtSlab == 126)
        #expect(ids.landscape == 127)
        #expect(ids.wall == 33)
    }

    @Test("default TileIDs are zero")
    func defaults() {
        let ids = TileIDs()
        #expect(ids.veiled == 0 && ids.bloom == 0 && ids.builtSlab == 0 && ids.landscape == 0 && ids.wall == 0)
    }
}
