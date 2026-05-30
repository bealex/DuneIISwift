import DuneIIContracts
import DuneIIWorld

/// The `Script_Team_*` op-14 natives operating on the running team (`g_scriptCurrentTeam`, here
/// `state.teams[slot]`). Plain explicit-param functions — no stack peeking in the logic — each a literal
/// transcription of OpenDUNE `src/script/team.c`. The getters + the recruit/target "brain" natives live
/// here; the order-issuing natives (which need the unit-action layer) arrive in a follow-up slice.
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
        state.teams[slot].position = Tile32(x: averageX << 8, y: averageY << 8)   // Tile_MakeXY

        var distance: UInt16 = 0
        var find2 = PoolFind(houseID: houseID)
        while let u = state.unitFind(&find2) {
            if slot != Int(state.units[u].team) - 1 { continue }
            distance &+= Tile32.distanceRoundedUp(from: state.units[u].o.position, to: state.teams[slot].position)
        }
        distance /= count

        if state.teams[slot].target == 0 || state.teams[slot].targetTile == 0 { return distance }
        if Tile32.distancePacked(Tile32.packXY(x: averageX, y: averageY),
                                 state.indexGetTile(state.teams[slot].target).packed) <= 10 {
            state.teams[slot].targetTile = 2
        }
        return distance
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
                from: state.units[u].o.position.packed, to: state.indexGetTile(target).packed)
            return target
        }
        return 0
    }
}
