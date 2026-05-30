import Foundation
import Testing
import DuneIIFormats
import DuneIIWorld
@testable import DuneIIScenarios

@Suite("Scenario terrain")
struct ScenarioTerrainTests {
    private func iconMap() throws -> IconMap? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/ScenariosTests → repo root
        guard let data = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP"))
        else { return nil }
        return try IconMap(data)
    }

    @Test("local coordinates map into the scale-0 playable rectangle")
    func mapping() {
        let t = ScenarioTerrain(seed: 1)
        #expect(t.mapPacked(lx: 0, ly: 0) == UInt16(t.originY * 64 + t.originX))
        #expect(t.mapPacked(lx: 7, ly: 7) == UInt16((t.originY + 7) * 64 + (t.originX + 7)))
        // Every tile inside [1, 62] in both axes (valid at mapScale 0).
        for ly in 0 ..< 8 {
            for lx in 0 ..< 8 {
                #expect(t.mapPacked(lx: lx, ly: ly) & 0xC000 == 0)
            }
        }
    }

    @Test("apply lays natural Map_CreateLandscape terrain — reproducible, with varied tiles")
    func apply() throws {
        guard let icon = try iconMap() else { return }   // needs the install

        func built(_ seed: UInt32) -> GameState {
            var s = GameState()
            s.tileIDs = TileIDs(iconMap: icon) ?? TileIDs()
            ScenarioTerrain(seed: seed).apply(to: &s, iconMap: icon)
            return s
        }

        let a = built(3), b = built(3), c = built(8)
        let groundA = a.map.map(\.groundTileID)
        #expect(groundA == b.map.map(\.groundTileID))   // same seed ⇒ identical terrain
        #expect(groundA != c.map.map(\.groundTileID))   // a different seed differs

        // The generated map isn't a flat fill — it carries transition/feature tiles.
        #expect(Set(groundA).count > 4)
    }
}
