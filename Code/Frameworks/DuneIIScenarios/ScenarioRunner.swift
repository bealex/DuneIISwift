import DuneIISimulation
import DuneIIWorld

/// One unit's observable state at a tick — what the visual harness draws and the golden test compares.
public struct UnitSnapshot: Sendable, Equatable {
    public let packed: UInt16
    public let orientation: Int8
    public let hitpoints: UInt16
    public let alive: Bool
}

public extension ScenarioWorld {
    /// The current per-unit snapshot (in `unitSlots` order).
    func snapshot() -> [UnitSnapshot] {
        unitSlots.map { slot in
            let u = state.units[slot]
            return UnitSnapshot(packed: u.o.position.packed,
                                orientation: u.orientation[0].current,
                                hitpoints: u.o.hitpoints,
                                alive: u.o.flags.contains(.used))
        }
    }

    /// Advance one tick by running the real `Simulation.tick()` — the full four-phase loop with the
    /// `GameLoop_Unit` cadence (movement / rotation / script / …). With the movement cluster ported, a
    /// unit ordered to move now actually crosses the terrain here; attack/guard units run their scripts
    /// until they reach an unported native (then halt cleanly — they aim but don't yet fire).
    mutating func tick() {
        var sim = Simulation(state: state, scriptInfo: runner.scriptInfo)
        sim.tick()
        state = sim.state
    }

    /// Run `ticks` ticks, returning the snapshot before tick 0 and after each tick (`ticks + 1` frames).
    mutating func run(ticks: Int) -> [[UnitSnapshot]] {
        var frames = [snapshot()]
        for _ in 0 ..< ticks {
            tick()
            frames.append(snapshot())
        }
        return frames
    }
}
