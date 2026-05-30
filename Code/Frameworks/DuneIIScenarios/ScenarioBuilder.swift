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
    public let terrain: ScenarioTerrain
}

/// Lays out a `GameState` for a `TestScenario`: terrain + two houses + the units (positions + initial
/// actions) + an optional building. The unit-category EMC program (`unitScript`) and the `iconMap` are
/// supplied by the caller (the app / the tests load them from `Resources/`).
public struct ScenarioBuilder {
    public let iconMap: IconMap
    public let unitScript: ScriptInfo
    public let player: HouseID
    public let enemy: HouseID

    public init(iconMap: IconMap, unitScript: ScriptInfo,
                player: HouseID = .harkonnen, enemy: HouseID = .ordos) {
        self.iconMap = iconMap
        self.unitScript = unitScript
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

        let terrain = ScenarioTerrain(seed: scenario.terrainSeed)
        terrain.apply(to: &state, iconMap: iconMap)
        // Point the viewport at the region so the lab's units script at full speed (not the off-viewport
        // 3-opcode throttle) — the lab is for visual assessment, not oracle-pinned parity.
        state.viewportPosition = Tile32.packXY(x: UInt16(terrain.originX), y: UInt16(terrain.originY))

        let actions = UnitActions()
        let runner = UnitScriptRunner(scriptInfo: unitScript)
        var slots: [Int] = []

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
                placeBuilding(&state, player, terrain, lx: 3, ly: 3)
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
        }

        return ScenarioWorld(state: state, runner: runner, actions: actions, unitSlots: slots, terrain: terrain)
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

    private func placeBuilding(_ state: inout GameState, _ house: HouseID,
                               _ terrain: ScenarioTerrain, lx: Int, ly: Int) {
        let slot = state.structureAllocate(index: Pool.structureIndexInvalid,
                                            type: UInt8(StructureType.windtrap.rawValue))!
        state.structures[slot].o.houseID = UInt8(house.rawValue)
        state.structures[slot].o.position = Tile32.unpack(terrain.mapPacked(lx: lx, ly: ly))
        state.structures[slot].o.hitpoints = StructureInfo[.windtrap].o.hitpoints
        state.structures[slot].o.flags.insert(.byScenario)
        state.structures[slot].state = .idle
        state.structureUpdateMap(slot)
    }
}
