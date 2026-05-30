import DuneIIContracts
import DuneIIFormats
import DuneIISimulation
import DuneIIWorld

/// A built scenario: the laid-out `GameState`, the script runner/actions used to drive it, and the
/// placed unit slots. `state` is `var` so the runner can tick it.
public struct ScenarioWorld {
    public var state: GameState
    public let runner: UnitScriptRunner
    public let actions: UnitActions
    public let unitSlots: [Int]      // [unit1] for moving / moveAroundBuilding, else [unit1, unit2]
    public let structureSlots: [Int] // the scenario's placed structure pool slots (the completion target, if any)
    public let kind: ScenarioKind    // so the lab can decide when the scenario is "done" (see `outcome()`)
    public let terrain: ScenarioTerrain
    public let structureScript: ScriptInfo   // BUILD.EMC — so structures run their scripts in the runner
    /// Advance the explosion animations each tick (impacts/deaths/destruction). Off by default so the
    /// golden runner matches the oracle (which doesn't tick explosions); `scenariolab` turns it on.
    public var tickExplosions = false
}

/// Lays out a `GameState` for a `TestScenario`: terrain + two houses + the units (positions + initial
/// actions) + an optional building. The unit-category EMC program (`unitScript`) and the `iconMap` are
/// supplied by the caller (the app / the tests load them from `Resources/`).
public struct ScenarioBuilder {
    public let iconMap: IconMap
    public let unitScript: ScriptInfo
    public let structureScript: ScriptInfo
    public let player: HouseID
    public let enemy: HouseID

    public init(iconMap: IconMap, unitScript: ScriptInfo, structureScript: ScriptInfo,
                player: HouseID = .harkonnen, enemy: HouseID = .ordos) {
        self.iconMap = iconMap
        self.unitScript = unitScript
        self.structureScript = structureScript
        self.player = player
        self.enemy = enemy
    }

    public func build(_ scenario: TestScenario) -> ScenarioWorld {
        var state = GameState()
        state.playerHouseID = UInt8(player.rawValue)
        state.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        state.iconMap = iconMap
        state.mapScale = 0
        _ = state.houseAllocate(index: UInt8(player.rawValue))
        _ = state.houseAllocate(index: UInt8(enemy.rawValue))
        state.houses[Int(player.rawValue)].unitCountMax = 100
        state.houses[Int(enemy.rawValue)].unitCountMax = 100
        // Let the player hold credits without a spice silo (the starting no-silo allowance). Otherwise the
        // House loop's storage clamp would wipe the economy scenarios' starting credits to 0 on tick 1
        // (a lone factory/barracks/windtrap has no credit storage).
        state.playerCreditsNoSilo = 5000

        let terrain = ScenarioTerrain(seed: scenario.terrainSeed)
        terrain.apply(to: &state, iconMap: iconMap)
        // Point the viewport at the region so the lab's units script at full speed (not the off-viewport
        // 3-opcode throttle) — the lab is for visual assessment, not oracle-pinned parity.
        state.viewportPosition = Tile32.packXY(x: UInt16(terrain.originX), y: UInt16(terrain.originY))

        let actions = UnitActions()
        let runner = UnitScriptRunner(scriptInfo: unitScript)
        var slots: [Int] = []
        var structSlots: [Int] = []

        switch scenario.kind {
            case .moving:
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 0, ly: 0)
                move(&state, u1, toLocal: (7, 7), terrain, actions)
                slots = [u1]

            case .closeAttack:
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 3, ly: 3)
                let u2 = place(&state, scenario.unit2, enemy, terrain, lx: 4, ly: 3)
                attack(&state, attacker: u2, target: u1, actions)
                slots = [u1, u2]

            case .farAttack:
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 1, ly: 1)
                let u2 = place(&state, scenario.unit2, enemy, terrain, lx: 6, ly: 6)
                attack(&state, attacker: u2, target: u1, actions)
                slots = [u1, u2]

            case .guarding:
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 2, ly: 2)
                actions.setAction(slot: u1, action: UInt8(ActionType.guard_.rawValue), scriptInfo: unitScript, in: &state)
                let u2 = place(&state, scenario.unit2, enemy, terrain, lx: 7, ly: 7)
                move(&state, u2, toLocal: (2, 2), terrain, actions)
                slots = [u1, u2]

            case .moveAroundBuilding:
                structSlots = [placeStructure(&state, .windtrap, player, terrain, lx: 3, ly: 3)]
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 0, ly: 0)
                move(&state, u1, toLocal: (7, 7), terrain, actions)
                slots = [u1]

            case .deviate:
                // Demonstrate Unit_Deviate: an enemy deviator mind-controls the player's unit, which
                // flips to the enemy house (rendered in the enemy's colours). Forced (probability 256)
                // so the demo always deviates; the RNG-gated path is covered by UnitCombatTests.
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 2, ly: 3)
                let u2 = place(&state, scenario.unit2, enemy, terrain, lx: 4, ly: 3)
                UnitCombat(movement: UnitMovement(scriptInfo: unitScript))
                    .deviate(slot: u1, probability: 256, houseID: UInt8(enemy.rawValue), in: &state)
                slots = [u1, u2]

            case .attackStructure:
                // A player tank attacks the enemy's windtrap. It's pre-weakened so a single tank shot drops
                // it to 0 HP (a tank only fires once at a structure), so the demo actually shows the BUILD.EMC
                // death branch (Explode → Delay → Destroy → Structure_Remove) run in GameLoop_Structure.
                let s = placeStructure(&state, .windtrap, enemy, terrain, lx: 4, ly: 3)
                structSlots = [s]
                state.structures[s].o.hitpoints = 20
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 2, ly: 3)
                actions.setAction(slot: u1, action: UInt8(ActionType.attack.rawValue), scriptInfo: unitScript, in: &state)
                state.units[u1].targetAttack = state.indexEncode(UInt16(state.structures[s].o.index), type: .structure)
                slots = [u1]

            case .turretDefense:
                // A player gun-turret defends on its own: its BUILD.EMC script runs FindTargetUnit → aim →
                // Fire at the approaching (seen) enemy unit, which it damages.
                structSlots = [placeStructure(&state, .turret, player, terrain, lx: 3, ly: 3)]
                let u2 = place(&state, scenario.unit2, enemy, terrain, lx: 7, ly: 3)
                state.units[u2].o.seenByHouses |= UInt8(1 << player.rawValue)   // the turret can see it
                move(&state, u2, toLocal: (4, 3), terrain, actions)             // it advances toward the base
                slots = [u2]

            case .factoryProduce:
                // A Light Factory builds a Trike: `tickStructure`'s factory branch drains credits + advances
                // the build countdown each structure-tick, completing to READY. A queued (hidden) trike is
                // linked so the build is faithful.
                let f = placeStructure(&state, .lightVehicle, player, terrain, lx: 3, ly: 3)
                structSlots = [f]
                settle(&state, f)
                state.houses[Int(player.rawValue)].credits = 4000
                let built = state.unitAllocate(index: 0, type: UInt8(UnitType.trike.rawValue),
                                               houseID: UInt8(player.rawValue))!
                state.units[built].o.hitpoints = UnitInfo[.trike].o.hitpoints
                state.units[built].o.flags.insert(.isNotOnMap)                  // in the factory
                state.structures[f].o.linkedID = UInt8(built)
                state.structures[f].objectType = UInt16(UnitType.trike.rawValue)
                state.structures[f].state = .busy
                state.structures[f].countDown = 1536                            // ~6 structure-ticks of build
                slots = []

            case .repairBuilding:
                // A damaged windtrap self-repairs: `tickStructure`'s repair branch heals +5 HP each
                // structure-tick (billing the 1.07 repair cost) until it reaches full HP.
                let w = placeStructure(&state, .windtrap, player, terrain, lx: 3, ly: 3)
                structSlots = [w]
                settle(&state, w)
                state.structures[w].o.hitpoints = StructureInfo[.windtrap].o.hitpoints / 2
                state.structures[w].o.flags.insert(.repairing)
                state.houses[Int(player.rawValue)].credits = 4000
                slots = []

            case .upgradeBuilding:
                // A barracks upgrades: `tickStructure`'s upgrade branch pays `buildCredits/40` per
                // structure-tick and steps `upgradeTimeLeft` to 0, then bumps `upgradeLevel`.
                let b = placeStructure(&state, .barracks, player, terrain, lx: 3, ly: 3)
                structSlots = [b]
                settle(&state, b)
                state.structures[b].o.flags.insert(.upgrading)
                state.structures[b].upgradeTimeLeft = 30                        // ~6 structure-ticks → level up
                state.houses[Int(player.rawValue)].credits = 4000
                slots = []
        }

        return ScenarioWorld(state: state, runner: runner, actions: actions, unitSlots: slots,
                             structureSlots: structSlots, kind: scenario.kind,
                             terrain: terrain, structureScript: structureScript)
    }

    // MARK: - Placement helpers

    private func place(_ state: inout GameState, _ type: UnitType, _ house: HouseID,
                       _ terrain: ScenarioTerrain, lx: Int, ly: Int) -> Int {
        let slot = state.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: UInt8(house.rawValue))!
        let p = terrain.mapPacked(lx: lx, ly: ly)
        state.units[slot].o.position = Tile32.unpack(p)
        state.units[slot].o.hitpoints = UnitInfo[type].o.hitpoints
        state.units[slot].o.flags.insert(.byScenario)
        state.map[Int(p)].hasUnit = true
        state.map[Int(p)].index = UInt8(slot + 1)
        return slot
    }

    private func move(_ state: inout GameState, _ slot: Int, toLocal: (Int, Int),
                      _ terrain: ScenarioTerrain, _ actions: UnitActions) {
        // The real move order (`Unit_SetDestination`): SetAction(Move) loads the move script (and clears
        // `currentDestination`), then set `targetMove` to the destination tile + reset the route. The
        // move script reads `targetMove` and routes to it via `Script_Unit_CalculateRoute`.
        actions.setAction(slot: slot, action: UInt8(ActionType.move.rawValue), scriptInfo: unitScript, in: &state)
        let p = terrain.mapPacked(lx: toLocal.0, ly: toLocal.1)
        state.units[slot].targetMove = state.indexEncode(p, type: .tile)
        state.units[slot].route[0] = 0xFF
    }

    private func attack(_ state: inout GameState, attacker: Int, target: Int, _ actions: UnitActions) {
        actions.setAction(slot: attacker, action: UInt8(ActionType.attack.rawValue), scriptInfo: unitScript, in: &state)
        state.units[attacker].targetAttack = state.indexEncode(state.units[target].o.index, type: .unit)
    }

    @discardableResult
    private func placeStructure(_ state: inout GameState, _ type: StructureType, _ house: HouseID,
                                _ terrain: ScenarioTerrain, lx: Int, ly: Int) -> Int {
        let slot = state.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        state.structures[slot].o.houseID = UInt8(house.rawValue)
        // A structure stores its tile *corner*, not the centred sub-tile (`Structure_Place: &= 0xFF00`) —
        // matters for a unit-vs-structure aim (see insight world-structure-corner-position).
        let p = terrain.mapPacked(lx: lx, ly: ly)
        state.structures[slot].o.position = Tile32(x: Tile32.unpack(p).x & 0xFF00, y: Tile32.unpack(p).y & 0xFF00)
        state.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
        state.structures[slot].o.flags.insert(.byScenario)
        state.structures[slot].state = .idle
        state.structureUpdateMap(slot)
        return slot
    }

    /// Suspend a freshly-placed structure's BUILD.EMC script (a long `script.delay`) so its one-time
    /// placement animation — a `SetState(-1)/.../SetState(-2)` sequence (BUILD.EMC `Jump 0`) — doesn't
    /// overwrite the `state` the economy scenarios set up. In real play the structure has long since
    /// settled into its steady main loop before it produces/repairs/upgrades; this demo starts it
    /// mid-production, so we hold the animation off and let `tickStructure` (the economy) run in isolation.
    private func settle(_ state: inout GameState, _ slot: Int) {
        state.structures[slot].o.script.delay = 10_000
    }
}
