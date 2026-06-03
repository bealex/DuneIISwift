import DuneIIContracts
import DuneIIWorld

/// The `Script_Team_*` op-14 natives operating on the running team (`g_scriptCurrentTeam`, here
/// `state.teams[slot]`). Plain explicit-param functions — no stack peeking in the logic — each a literal
/// transcription of OpenDUNE `src/script/team.c`. Covers the full table: the getters, the recruit/target
/// "brain" natives, the order-issuing natives (`moveOrGuardMembers`/`issueAttackOrders`, which take the
/// unit-action layer explicitly), and the `Load`/`Load2` script switch.
struct TeamScriptFunctions: Sendable {
    /// `Script_Team_GetMembers` (`team.c:28`): the team's current member count.
    func getMembers(slot: Int, in state: GameState) -> UInt16 { state.teams[slot].members }

    /// `Script_Team_GetVariable6` (`team.c:42`): the team's `minMembers` (OpenDUNE's `variable_06`).
    func getVariable6(slot: Int, in state: GameState) -> UInt16 { state.teams[slot].minMembers }

    /// `Script_Team_GetTarget` (`team.c:56`): the team's encoded target.
    func getTarget(slot: Int, in state: GameState) -> UInt16 { state.teams[slot].target }

    /// `Script_Team_AddClosestUnit` (`team.c:70`): recruit the nearest eligible unit into the team and
    /// return the team's resulting free slots (0 if full or none found). Eligible = same house, scenario-
    /// created, not a saboteur, matching `movementType`. A team-less unit is preferred (`closest`); failing
    /// that, a unit poached from an under-strength team (`closest2`, only if its team is at/below `minMembers`).
    func addClosestUnit(slot: Int, in state: inout GameState) -> UInt16 {
        if state.teams[slot].members >= state.teams[slot].maxMembers { return 0 }
        let houseID = state.teams[slot].houseID
        let teamMove = Int(state.teams[slot].movementType)
        let teamPos = state.teams[slot].position

        var closest = -1, closest2 = -1
        var minDistance: UInt16 = 0, minDistance2: UInt16 = 0
        var find = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find) {
            if !state.units[u].o.flags.contains(.byScenario) { continue }
            if state.units[u].o.type == UInt8(UnitType.saboteur.rawValue) { continue }
            guard let ut = UnitType(rawValue: Int(state.units[u].o.type)) else { continue }

            if UnitInfo[ut].movementType.rawValue != teamMove { continue }

            if state.units[u].team == 0 {
                let distance = Tile32.distance(from: teamPos, to: state.units[u].o.position)
                if distance >= minDistance && minDistance != 0 { continue }
                minDistance = distance
                closest = u
                continue
            }
            let t2 = Int(state.units[u].team) - 1
            if state.teams[t2].members > state.teams[t2].minMembers { continue }
            let distance = Tile32.distance(from: teamPos, to: state.units[u].o.position)
            if distance >= minDistance2 && minDistance2 != 0 { continue }
            minDistance2 = distance
            closest2 = u
        }

        if closest == -1 { closest = closest2 }
        if closest == -1 { return 0 }
        state.unitRemoveFromTeam(closest)
        return state.unitAddToTeam(closest, team: slot)
    }

    /// `Script_Team_GetAverageDistance` (`team.c:132`): set the team's `position` to the average of its
    /// members' tile positions and return their average distance from it. If the team has a target and a set
    /// `targetTile`, flips `targetTile` to 2 once the members' centroid is within 10 tiles of the target.
    func getAverageDistance(slot: Int, in state: inout GameState) -> UInt16 {
        let houseID = state.teams[slot].houseID
        var averageX: UInt16 = 0, averageY: UInt16 = 0, count: UInt16 = 0

        var find = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find) {
            if slot != Int(state.units[u].team) - 1 { continue }
            count &+= 1
            averageX &+= (state.units[u].o.position.x >> 8) & 0x3f
            averageY &+= (state.units[u].o.position.y >> 8) & 0x3f
        }
        if count == 0 { return 0 }
        averageX /= count
        averageY /= count
        state.teams[slot].position = Tile32(x: averageX << 8, y: averageY << 8)  // Tile_MakeXY

        var distance: UInt16 = 0
        var find2 = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find2) {
            if slot != Int(state.units[u].team) - 1 { continue }
            distance &+= Tile32.distanceRoundedUp(from: state.units[u].o.position, to: state.teams[slot].position)
        }
        distance /= count

        if state.teams[slot].target == 0 || state.teams[slot].targetTile == 0 { return distance }
        if Tile32.distancePacked(
            Tile32.packXY(x: averageX, y: averageY),
            state.indexGetTile(state.teams[slot].target).packed
        ) <= 10 {
            state.teams[slot].targetTile = 2
        }
        return distance
    }

    /// `Script_Team_Unknown0543` (`team.c:196`): keep the team's members loosely massed near the team's
    /// `position`. For each member, compare how its own move-destination progress relates to the team
    /// centre: a unit that has strayed too far (beyond `distance`, accounting for whether it's already
    /// heading inward) is ordered to Move to a fresh random tile within `distance` of the centre; the rest
    /// Guard. Returns how many were (re)ordered to Move. Needs the unit-action layer (`Unit_SetAction` /
    /// `Unit_SetDestination`), so it clean-halts without the unit runner.
    func moveOrGuardMembers(
        slot: Int,
        distance: UInt16,
        unitScript: ScriptInfo,
        actions: UnitActions,
        unitFuncs: UnitScriptFunctions,
        in state: inout GameState
    ) -> UInt16 {
        let houseID = state.teams[slot].houseID
        let teamPos = state.teams[slot].position
        var count: UInt16 = 0

        var find = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find) {
            if slot != Int(state.units[u].team) - 1 { continue }

            let unitPos = state.units[u].o.position
            let distanceUnitTeam = Tile32.distanceRoundedUp(from: unitPos, to: teamPos)
            let distanceUnitDest: UInt16
            let distanceTeamDest: UInt16
            if state.units[u].targetMove != 0 {
                let destTile = state.indexGetTile(state.units[u].targetMove)
                distanceUnitDest = Tile32.distanceRoundedUp(from: unitPos, to: destTile)
                distanceTeamDest = Tile32.distanceRoundedUp(from: teamPos, to: destTile)
            } else {
                distanceUnitDest = 64
                distanceTeamDest = 64
            }

            if (distanceUnitDest < distanceTeamDest && (distance &+ 2) < distanceUnitTeam)
                || (distanceUnitDest >= distanceTeamDest && distanceUnitTeam > distance)
            {
                actions.setAction(slot: u, action: UInt8(ActionType.move.rawValue), scriptInfo: unitScript, in: &state)
                let tile = Tile32.moveByRandom(teamPos, distance: distance << 4, center: true, rng: &state.random256)
                unitFuncs.unitSetDestination(slot: u, state.indexEncode(tile.packed, type: .tile), in: &state)
                count &+= 1
                continue
            }
            actions.setAction(slot: u, action: UInt8(ActionType.guard_.rawValue), scriptInfo: unitScript, in: &state)
        }
        return count
    }

    /// `Script_Team_Unknown0788` (`team.c:350`): order every member to attack the team's `target`. A
    /// member already attacking that target from within fire range (and not still moving) is left alone;
    /// otherwise it's set to Attack, sent to a firing position offset a random direction-quadrant around
    /// the target (falling back to the target tile itself if that spot is occupied), and given the target.
    /// No-op (returns 0) when the team has no target. Needs the unit-action layer.
    func issueAttackOrders(
        slot: Int,
        unitScript: ScriptInfo,
        actions: UnitActions,
        unitFuncs: UnitScriptFunctions,
        in state: inout GameState
    ) -> UInt16 {
        let target = state.teams[slot].target
        if target == 0 { return 0 }
        let houseID = state.teams[slot].houseID
        let targetTile = state.indexGetTile(target)

        var find = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find) {
            if Int(state.units[u].team) - 1 != slot { continue }
            // (OpenDUNE re-checks `t->target == 0 → GUARD` here; we returned above and target is constant.)
            guard let ut = UnitType(rawValue: Int(state.units[u].o.type)) else { continue }

            let distance = UnitInfo[ut].fireDistance &<< 8

            if state.units[u].actionID == UInt8(ActionType.attack.rawValue) && state.units[u].targetAttack == target {
                if state.units[u].targetMove != 0 { continue }
                if Tile32.distance(from: state.units[u].o.position, to: targetTile) >= distance { continue }
            }

            if state.units[u].actionID != UInt8(ActionType.attack.rawValue) {
                actions.setAction(
                    slot: u,
                    action: UInt8(ActionType.attack.rawValue),
                    scriptInfo: unitScript,
                    in: &state
                )
            }

            // A firing position: the target's facing quadrant toward the unit, jittered, `distance` out.
            let dirByte = Int(UInt8(bitPattern: Tile32.direction(from: targetTile, to: state.units[u].o.position)))
            var orientation = Int16(dirByte & 0xC0) &+ Int16(truncatingIfNeeded: state.randomLCG.range(0, 127))
            if orientation < 0 { orientation &+= 256 }
            let packed = Tile32.moveByDirection(targetTile, orientation: orientation, distance: distance).packed

            let occupied = state.unitGetByPackedTile(packed) != nil || state.structureGetByPackedTile(packed) != nil
            let destination = occupied ? targetTile.packed : packed
            unitFuncs.unitSetDestination(slot: u, state.indexEncode(destination, type: .tile), in: &state)
            unitFuncs.unitSetTarget(slot: u, target, in: &state)
        }
        return 0
    }

    /// `Script_Team_Load` (`team.c:296`): switch the team to action-script `type`, reloading its EMC
    /// (`Script_Reset` + `Script_Load`). A no-op if it's already that action. The reload targets the
    /// passed-in `engine` (the live VM copy), not `state.teams[slot].script` — the runner writes the
    /// engine back after the run, so mutating `state` here would be clobbered.
    func load(
        slot: Int,
        type: UInt16,
        interpreter: any ScriptInterpreter,
        scriptInfo: ScriptInfo,
        engine: inout ScriptEngine,
        in state: inout GameState
    ) -> UInt16 {
        if state.teams[slot].action == type { return 0 }
        state.teams[slot].action = type
        interpreter.load(&engine, info: scriptInfo, typeID: Int(type & 0xFF))
        return 0
    }

    /// `Script_Team_Load2` (`team.c:322`): reload the team's *starting* action script (`actionStart`).
    func load2(
        slot: Int,
        interpreter: any ScriptInterpreter,
        scriptInfo: ScriptInfo,
        engine: inout ScriptEngine,
        in state: inout GameState
    ) -> UInt16 {
        load(
            slot: slot,
            type: state.teams[slot].actionStart,
            interpreter: interpreter,
            scriptInfo: scriptInfo,
            engine: &engine,
            in: &state
        )
    }

    /// `Script_Team_FindBestTarget` (`team.c:256`): scan the team's members for the first non-zero best
    /// target (`Unit_FindBestTargetEncoded`, mode 4 for a kamikaze team else 0). A target already equal to
    /// the team's is returned as-is; a new one is stored along with a `targetTile` in its rough direction.
    func findBestTarget(slot: Int, targets: TargetFinder, in state: inout GameState) -> UInt16 {
        let houseID = state.teams[slot].houseID
        let mode: UInt16 = state.teams[slot].action == UInt16(TeamActionType.kamikaze.rawValue) ? 4 : 0

        var find = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find) {
            if Int(state.units[u].team) - 1 != slot { continue }
            let target = targets.findBestTargetEncoded(slot: u, mode: mode, in: &state)
            if target == 0 { continue }
            if state.teams[slot].target == target { return target }
            state.teams[slot].target = target
            state.teams[slot].targetTile = state.tileGetTileInDirectionOf(
                from: state.units[u].o.position.packed,
                to: state.indexGetTile(target).packed
            )
            return target
        }
        return 0
    }
}
