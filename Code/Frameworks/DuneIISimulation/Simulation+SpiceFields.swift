import DuneIIContracts
import DuneIIWorld

public extension Simulation {
    /// Detonate the scenario's `[MAP] Field` spice fields once, before the first GameLoop —
    /// `Scenario_Load_Map_Field` (`scenario.c:328`) calls `Map_Bloom_ExplodeSpice(packed, HOUSE_INVALID)` at
    /// **load** for each field tile (a radius-5 spice circle, no bloom sprite). The World loader can't reach
    /// the sim's bloom primitive, so the tiles are stashed in `scenario.spiceFields`; this drains them. Called
    /// from `tick()` on the first tick the list is non-empty (ahead of the GameLoops), so the fill — and its
    /// `Map_FillCircleWithSpice` RNG draws — land before any per-tick draws, exactly as the oracle fills fields
    /// at load ahead of `g_tickScenarioStart`. Idempotent: the list is cleared whether or not the unit layer
    /// is present.
    mutating func applyScenarioSpiceFields() {
        let fields = state.scenario.spiceFields
        state.scenario.spiceFields = []
        guard let movement = unitScript?.movement else { return }
        for packed in fields {
            movement.mapBloomExplodeSpice(packed: packed, houseID: Pool.houseInvalid, in: &state)
        }
    }
}
