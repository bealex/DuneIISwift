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

    /// The unit-script runner (VM + op-14 dispatch + the movement cluster), present when a `scriptInfo`
    /// (the bridged `UNIT.EMC`) was supplied. `GameLoop_Unit` runs unit scripts + movement only when it
    /// exists; without it the unit phase still runs the cadence + the orientation/idle work.
    public var unitScript: UnitScriptRunner?

    /// The structure-script runner (VM + op-14 dispatch over `g_scriptFunctionsStructure`), present when a
    /// `structureScriptInfo` (the bridged `BUILD.EMC`) was supplied alongside the unit one. `GameLoop_Structure`
    /// runs structure scripts only when it exists. It shares the unit runner's `UnitCombat` so the structure
    /// death natives reach the same explosion / unit-spawn layer.
    public var structureScript: StructureScriptRunner?

    public init(
        state: GameState,
        scriptInfo: ScriptInfo? = nil,
        structureScriptInfo: ScriptInfo? = nil,
        unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives(),
        mapPrimitives: any MapPrimitives = DefaultMapPrimitives(),
        housePrimitives: any HousePrimitives = DefaultHousePrimitives()
    ) {
        self.state = state
        self.unitPrimitives = unitPrimitives
        self.mapPrimitives = mapPrimitives
        self.housePrimitives = housePrimitives
        let unitRunner = scriptInfo.map {
            UnitScriptRunner(scriptInfo: $0, unitPrimitives: unitPrimitives,
                             mapPrimitives: mapPrimitives, housePrimitives: housePrimitives)
        }
        self.unitScript = unitRunner
        // A structure script needs the unit layer (its death natives spawn units + reuse the explosion
        // path), so it's built only when both EMCs are present.
        self.structureScript = (structureScriptInfo != nil && unitRunner != nil)
            ? StructureScriptRunner(scriptInfo: structureScriptInfo!, combat: unitRunner!.combat,
                                    interpreter: unitRunner!.interpreter)
            : nil
    }

    public init(
        random256Seed: UInt32 = 0, randomLCGSeed: UInt16 = 0,
        scriptInfo: ScriptInfo? = nil,
        structureScriptInfo: ScriptInfo? = nil,
        unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives(),
        mapPrimitives: any MapPrimitives = DefaultMapPrimitives(),
        housePrimitives: any HousePrimitives = DefaultHousePrimitives()
    ) {
        self.init(state: GameState(random256Seed: random256Seed, randomLCGSeed: randomLCGSeed),
                  scriptInfo: scriptInfo, structureScriptInfo: structureScriptInfo,
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
        let runner = unitScript

        var find = PoolFind()
        while let slot = state.unitFind(&find) {
            guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { continue }
            let ui = UnitInfo[ut]

            if state.units[slot].o.flags.contains(.isNotOnMap) { continue }

            // Turret aim (tickUnknown4): point the turret at the attack target.
            if flags.contains(.unknown4) && state.units[slot].targetAttack != 0 && ui.o.flags.contains(.hasTurret) {
                let tile = state.indexGetTile(state.units[slot].targetAttack)
                var u = state.units[slot]
                let dir = Tile32.direction(from: u.o.position, to: tile)
                unitPrimitives.setOrientation(&u, orientation: dir, rotateInstantly: false, level: 1)
                state.units[slot] = u
            }

            // Movement (tickMovement): sub-tile step + fire-delay bookkeeping.
            if flags.contains(.movement) {
                runner?.movement.movementTick(slot: slot, in: &state)

                if state.units[slot].fireDelay != 0 {
                    if ui.movementType == .winger && !ui.flags.contains(.isNormalUnit) {
                        // A flying projectile homes on its scattered `currentDestination` — except a missile
                        // chasing an *aircraft* (a winger target) re-aims at the moving target each tick.
                        var tile = state.units[slot].currentDestination
                        if Tools.indexType(state.units[slot].targetAttack) == .unit,
                           let tslot = state.indexGetUnit(state.units[slot].targetAttack),
                           let tut = UnitType(rawValue: Int(state.units[tslot].o.type)),
                           UnitInfo[tut].movementType == .winger {
                            tile = state.indexGetTile(state.units[slot].targetAttack)
                        }
                        var u = state.units[slot]
                        let dir = Tile32.direction(from: u.o.position, to: tile)
                        unitPrimitives.setOrientation(&u, orientation: dir, rotateInstantly: false, level: 0)
                        state.units[slot] = u
                    }
                    state.units[slot].fireDelay &-= 1
                }
            }

            // Rotation (tickRotation): step the base + turret orientation toward their targets.
            if flags.contains(.rotation) {
                var u = state.units[slot]
                unitPrimitives.rotate(&u, level: 0)
                if ui.o.flags.contains(.hasTurret) { unitPrimitives.rotate(&u, level: 1) }
                state.units[slot] = u
            }

            // Blinking (tickBlinking) — highlight pulse is a render concern. (SEAM)

            // Deviation (tickDeviation): wear down a deviated unit.
            if flags.contains(.deviation), let runner {
                var engine = state.units[slot].o.script
                runner.movement.deviationDecrease(slot: slot, amount: 1, engine: &engine, in: &state)
                state.units[slot].o.script = engine
            }

            // Re-claim the unit's tile if nothing holds it (ground units only).
            if ui.movementType != .winger {
                let p = state.units[slot].o.position.packed
                if state.unitGetByPackedTile(p) == nil && state.structureGetByPackedTile(p) == nil {
                    state.unitUpdateMap(1, slot)
                }
            }

            // Sprite animation timers (tickUnknown5) — render-only. (SEAM)

            // Script (tickScript): run up to SCRIPT_UNIT_OPCODES_PER_TICK + 2 opcodes.
            if flags.contains(.script), let runner {
                if state.units[slot].o.script.delay == 0 {
                    if runner.interpreter.isLoaded(state.units[slot].o.script) {
                        // SCRIPT_UNIT_OPCODES_PER_TICK + 2, but an off-viewport unit (and not flagged
                        // scriptNoSlowdown) is throttled to 3 — `Map_IsPositionInViewport` (unit.c:289).
                        let inView = Tile32.isPositionInViewport(state.units[slot].o.position,
                                                                 viewport: state.viewportPosition)
                        let budget = (!ui.o.flags.contains(.scriptNoSlowdown) && !inView) ? 3 : 52
                        state.units[slot].o.script.variables[3] = UInt16(state.playerHouseID)
                        runner.run(slot: slot, in: &state, budget: budget)
                    }
                } else {
                    state.units[slot].o.script.delay &-= 1
                }
            }

            // Promote a queued action once the unit has finished moving.
            if state.units[slot].nextActionID == 0xFF { continue }
            if state.units[slot].currentDestination.x != 0 || state.units[slot].currentDestination.y != 0 { continue }
            if let runner {
                let next = state.units[slot].nextActionID
                runner.actions.setAction(slot: slot, action: next, scriptInfo: runner.scriptInfo, in: &state)
                state.units[slot].nextActionID = 0xFF
            }
        }
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

    /// `GameLoop_Structure` (`structure.c:53`). Advances the four structure tick cursors; when the **script**
    /// cursor fires, runs each structure's EMC script (3 opcodes) via `structureScript`. The degrade /
    /// structure-build-repair / palace activities advance their cursors but their bodies are seams (the
    /// campaign-degrade, BUILD/REPAIR/factory-production, and palace special-weapon slices). See
    /// `Documentation/Algorithms/StructureScript.md`.
    mutating func gameLoopStructure() {
        let g = state.timerGame

        // degrade (campaign>1 only — not modeled) + structure (BUILD/REPAIR — SEAM): advance cursors faithfully.
        if state.structureTick.degrade <= g {
            state.structureTick.degrade = g &+ UInt32(adjustToGameSpeed(normal: 10800, minimum: 5400, maximum: 21600, inverse: true))
        }
        if state.structureTick.structure <= g {
            state.structureTick.structure = g &+ UInt32(adjustToGameSpeed(normal: 30, minimum: 15, maximum: 60, inverse: true))
        }
        var tickScript = false
        if state.structureTick.script <= g {
            tickScript = true
            state.structureTick.script = g &+ 5
        }
        if state.structureTick.palace <= g {            // palace special weapon — SEAM
            state.structureTick.palace = g &+ 60
        }

        guard tickScript, let runner = structureScript else { return }

        var find = PoolFind()
        while let slot = state.structureFind(&find) {
            // SEAM: per-structure palace countdown, campaign degrade, and the BUILD/REPAIR/factory state machine.
            if state.structures[slot].o.script.delay != 0 {
                state.structures[slot].o.script.delay &-= 1
                continue
            }
            if runner.interpreter.isLoaded(state.structures[slot].o.script) {
                let executed = runner.run(slot: slot, in: &state, budget: 3)
                // OpenDUNE 1.07: a structure whose script errors before its 3 opcodes aborts the remaining
                // structures this tick (`if (!g_dune2_enhanced && i != 3) return;`).
                if executed != 3 { return }
            } else {
                // (Re)load the type's script — the start path and the death-script restart (Structure_Destroy
                // resets the script, so its death branch loads here with the death flag already set).
                guard let st = StructureType(rawValue: Int(state.structures[slot].o.type)) else { continue }
                state.structures[slot].o.script.reset()                          // Script_Reset
                var engine = state.structures[slot].o.script
                runner.interpreter.load(&engine, info: runner.scriptInfo, typeID: Int(st.rawValue))  // Script_Load
                state.structures[slot].o.script = engine
            }
        }
    }

    /// `GameLoop_House` — ported in a later Phase-3 slice (order-preserving stub for now).
    mutating func gameLoopHouse() {}
}
