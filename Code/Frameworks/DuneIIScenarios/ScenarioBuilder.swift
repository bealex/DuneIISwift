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
    public let structureScript: ScriptInfo   // BUILD.EMC — so structures run their scripts in the runner
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
                placeStructure(&state, .windtrap, player, terrain, lx: 3, ly: 3)
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
                state.structures[s].o.hitpoints = 20
                let u1 = place(&state, scenario.unit1, player, terrain, lx: 2, ly: 3)
                actions.setAction(slot: u1, action: UInt8(ActionType.attack.rawValue), scriptInfo: unitScript, in: &state)
                state.units[u1].targetAttack = state.indexEncode(UInt16(state.structures[s].o.index), type: .structure)
                slots = [u1]

            case .turretDefense:
                // A player gun-turret defends on its own: its BUILD.EMC script runs FindTargetUnit → aim →
                // Fire at the approaching (seen) enemy unit, which it damages.
                placeStructure(&state, .turret, player, terrain, lx: 3, ly: 3)
                let u2 = place(&state, scenario.unit2, enemy, terrain, lx: 7, ly: 3)
                state.units[u2].o.seenByHouses |= UInt8(1 << player.rawValue)   // the turret can see it
                move(&state, u2, toLocal: (4, 3), terrain, actions)             // it advances toward the base
                slots = [u2]
        }

        return ScenarioWorld(state: state, runner: runner, actions: actions, unitSlots: slots,
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
}
