import DuneIIContracts
import DuneIIWorld

/// The headless, deterministic game loop. Wraps a `GameState` and advances it one tick at a time:
/// the two-clock model + speed/pause, and the four-phase `tick()` (Team → Unit → Structure → House).
///
/// The per-type state machines that fill in each phase's per-entity work are exact EMC transcriptions
/// ported in later Phase-3 slices; the loop scaffolding + the `GameLoop_Unit` cadence are in place now.
/// See `Documentation/Architecture/SimulationLoop.md`.
public struct Simulation: Sendable {
    /// All mutable simulation state. A value type, so a copy is a full snapshot.
    public var state: GameState

    /// The replaceable native primitives. Each is injected so its implementation can be swapped
    /// (reference / optimized / instrumented / test); all default to the OpenDUNE-faithful ports.
    public var unitPrimitives: any UnitPrimitives
    public var mapPrimitives: any MapPrimitives
    public var housePrimitives: any HousePrimitives

    public init(
        state: GameState,
        unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives(),
        mapPrimitives: any MapPrimitives = DefaultMapPrimitives(),
        housePrimitives: any HousePrimitives = DefaultHousePrimitives()
    ) {
        self.state = state
        self.unitPrimitives = unitPrimitives
        self.mapPrimitives = mapPrimitives
        self.housePrimitives = housePrimitives
    }

    public init(
        random256Seed: UInt32 = 0, randomLCGSeed: UInt16 = 0,
        unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives(),
        mapPrimitives: any MapPrimitives = DefaultMapPrimitives(),
        housePrimitives: any HousePrimitives = DefaultHousePrimitives()
    ) {
        self.init(state: GameState(random256Seed: random256Seed, randomLCGSeed: randomLCGSeed),
                  unitPrimitives: unitPrimitives, mapPrimitives: mapPrimitives,
                  housePrimitives: housePrimitives)
    }

    /// One simulation tick: advance the clocks (pause-aware) then run the four game-loop phases.
    /// Mirrors the headless parity driver (`src/parity.c` `Parity_Run`).
    public mutating func tick() {
        state.timerGUI &+= 1
        if state.paused { return }
        state.timerGame &+= 1

        gameLoopTeam()
        gameLoopUnit()
        gameLoopStructure()
        gameLoopHouse()
        state.animationTick()   // structure animations (mutates the map ground tiles over time)
    }

    /// `Tools_AdjustToGameSpeed` with this run's `gameSpeed`.
    func adjustToGameSpeed(normal: UInt16, minimum: UInt16, maximum: UInt16, inverse: Bool) -> UInt16 {
        Tools.adjustToGameSpeed(normal: normal, minimum: minimum, maximum: maximum,
                                inverseSpeed: inverse, gameSpeed: state.gameSpeed)
    }
}

/// Which `GameLoop_Unit` sub-activities fire on a given tick.
public struct UnitTickFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let movement  = UnitTickFlags(rawValue: 1 << 0)
    public static let rotation  = UnitTickFlags(rawValue: 1 << 1)
    public static let blinking  = UnitTickFlags(rawValue: 1 << 2)
    public static let unknown4  = UnitTickFlags(rawValue: 1 << 3)
    public static let script    = UnitTickFlags(rawValue: 1 << 4)
    public static let unknown5  = UnitTickFlags(rawValue: 1 << 5)
    public static let deviation = UnitTickFlags(rawValue: 1 << 6)
}

extension Simulation {
    /// `GameLoop_Unit` (`src/unit.c:123`). Computes which sub-activities are due this tick (advancing
    /// their cursors), then runs the per-unit work for each. The cadence is faithful; the per-unit work
    /// (movement / rotation / script / … on each unit) is the per-type state-machine port arriving in
    /// the later Phase-3 slices.
    mutating func gameLoopUnit() {
        let flags = advanceUnitCadence()
        // TODO(Phase 3): iterate `state.unitFind` and apply the per-unit work gated by `flags`.
        _ = flags
    }

    /// Advance the seven `GameLoop_Unit` tick cursors against `timerGame` and return which fired.
    mutating func advanceUnitCadence() -> UnitTickFlags {
        let g = state.timerGame
        var flags: UnitTickFlags = []

        if state.unitTick.movement <= g {
            flags.insert(.movement); state.unitTick.movement = g &+ 3
        }
        if state.unitTick.rotation <= g {
            flags.insert(.rotation)
            state.unitTick.rotation = g &+ UInt32(adjustToGameSpeed(normal: 4, minimum: 2, maximum: 8, inverse: true))
        }
        if state.unitTick.blinking <= g {
            flags.insert(.blinking); state.unitTick.blinking = g &+ 3
        }
        if state.unitTick.unknown4 <= g {
            flags.insert(.unknown4); state.unitTick.unknown4 = g &+ 20
        }
        if state.unitTick.script <= g {
            flags.insert(.script); state.unitTick.script = g &+ 5
        }
        if state.unitTick.unknown5 <= g {
            flags.insert(.unknown5); state.unitTick.unknown5 = g &+ 5
        }
        if state.unitTick.deviation <= g {
            flags.insert(.deviation); state.unitTick.deviation = g &+ 60
        }
        return flags
    }

    /// `GameLoop_Team` — ported in a later Phase-3 slice (order-preserving stub for now).
    mutating func gameLoopTeam() {}

    /// `GameLoop_Structure` — ported in a later Phase-3 slice (order-preserving stub for now).
    mutating func gameLoopStructure() {}

    /// `GameLoop_House` — ported in a later Phase-3 slice (order-preserving stub for now).
    mutating func gameLoopHouse() {}
}
