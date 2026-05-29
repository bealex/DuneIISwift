import Testing
import DuneIIWorld
@testable import DuneIIScenarios

@Suite("Scenario terrain")
struct ScenarioTerrainTests {
    @Test("a seed produces a deterministic, reproducible sand/rock layout")
    func deterministic() {
        let a = ScenarioTerrain(seed: 7)
        let b = ScenarioTerrain(seed: 7)
        let c = ScenarioTerrain(seed: 8)
        #expect(a.kinds == b.kinds)
        #expect(a.kinds.count == 64)
        #expect(a.kinds != c.kinds)              // a different seed differs
        #expect(a.kinds.contains(.sand) && a.kinds.contains(.rock))   // both kinds present
    }

    @Test("local coordinates map into the scale-0 playable rectangle")
    func mapping() {
        let t = ScenarioTerrain(seed: 1)
        #expect(t.mapPacked(lx: 0, ly: 0) == UInt16(t.originY * 64 + t.originX))
        #expect(t.mapPacked(lx: 7, ly: 7) == UInt16((t.originY + 7) * 64 + (t.originX + 7)))
        // Every tile inside [1, 62] in both axes (valid at mapScale 0).
        for ly in 0 ..< 8 {
            for lx in 0 ..< 8 {
                let p = t.mapPacked(lx: lx, ly: ly)
                #expect(p & 0xC000 == 0)
            }
        }
    }

    @Test("apply fills the map with sand and stamps rock where the layout says so")
    func apply() {
        var s = GameState()
        var ids = TileIDs()
        ids.landscape = 100
        s.tileIDs = ids
        let t = ScenarioTerrain(seed: 3)
        t.apply(to: &s)
        for ly in 0 ..< 8 {
            for lx in 0 ..< 8 {
                let g = s.map[Int(t.mapPacked(lx: lx, ly: ly))].groundTileID
                let expected: UInt16 = t.kind(lx: lx, ly: ly) == .sand ? 100 : 116
                #expect(g == expected)
            }
        }
    }
}
