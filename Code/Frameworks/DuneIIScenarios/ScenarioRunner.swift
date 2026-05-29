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

    /// Advance one tick: tick each placed unit's script (honouring its `delay`). This is a simplified
    /// stand-in for `GameLoop_Unit`'s per-tick cadence — enough to drive the scripts; the full cadence
    /// (movement/rotation/blink/… sub-ticks) is wired in when those land. Until the movement/combat
    /// natives are ported the scripts halt early, so units stay put.
    mutating func tick() {
        for slot in unitSlots where state.units[slot].o.flags.contains(.used) {
            if state.units[slot].o.script.delay > 0 {
                state.units[slot].o.script.delay -= 1
                continue
            }
            runner.run(slot: slot, in: &state, budget: 50)
        }
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
