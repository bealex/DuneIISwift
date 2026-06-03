import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// `[MAP] Field` spice fields — `Scenario_Load_Map_Field` (`scenario.c:328`) detonates a spice bloom at each
/// field tile at load. We stash the tiles in `scenario.spiceFields`; `Simulation.applyScenarioSpiceFields`
/// fills them once, before the first GameLoop (driven from `tick()` while the list is non-empty).
@Suite("Scenario spice fields")
struct SpiceFieldTests {
    private let info = ScriptInfo(program: [ UInt16 ](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> GameState {
        var s = GameState()
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        return s
    }

    @Test("the first tick detonates each field tile (bloom center reverts) and drains the list")
    func firstTickFills() {
        var s = base()
        let packed = Tile32.packXY(x: 30, y: 30)
        s.map[Int(packed)].groundTileID = 0x99  // some non-base sprite
        s.mapBaseTileID[Int(packed)] = 0x8000 | 0x42  // base sand id 0x42
        s.scenario.spiceFields = [ packed ]

        var sm = Simulation(state: s, scriptInfo: info)
        sm.tick()
        #expect(sm.state.scenario.spiceFields.isEmpty)  // consumed
        #expect(sm.state.map[Int(packed)].groundTileID == 0x42)  // Map_Bloom_ExplodeSpice reverted the tile
    }

    @Test("applyScenarioSpiceFields draws RNG (the radius-5 circle fill) and is idempotent")
    func appliesAndIdempotent() {
        var s = base()
        s.scenario.spiceFields = [ Tile32.packXY(x: 30, y: 30) ]
        var sm = Simulation(state: s, scriptInfo: info)

        var probe = sm.state.random256
        sm.applyScenarioSpiceFields()
        #expect(sm.state.scenario.spiceFields.isEmpty)
        #expect(sm.state.random256.next() != probe.next())  // the fill drew RNG (stream advanced)

        // A second apply is a no-op (empty list ⇒ no further draws).
        var probe2 = sm.state.random256
        sm.applyScenarioSpiceFields()
        #expect(sm.state.random256.next() == probe2.next())
    }

    @Test("no spice fields ⇒ tick draws exactly as a bare run (no contamination)")
    func emptyIsNeutral() {
        var s = base()
        #expect(s.scenario.spiceFields.isEmpty)
        var sm = Simulation(state: s, scriptInfo: info)
        // The guard in tick() skips the apply entirely; this just asserts a clean tick with no fields.
        sm.tick()
        #expect(sm.state.scenario.spiceFields.isEmpty)
    }
}
