import DuneIIContracts
import DuneIIWorld

/// Unit combat effects — `Unit_Damage` (`unit.c:1530`) and friends. A faithful port that composes the
/// World pool/lifecycle ops (`Unit_RemovePlayer`, `Unit_UpdateMap`) + `UnitActions` (`Unit_SetAction`)
/// + `UnitMovement` (`Unit_Deviation_Decrease`). Lives beside `UnitMovement` (its sibling), reusing that
/// type's injected `actions`/`scriptInfo` so the script (re)loads stay in one place.
///
/// The audio (`Sound_Output_Feedback`), impact-explosion (`Map_MakeExplosion` #15), harvester-death
/// spice (`Map_FillCircleWithSpice`), and render-redraw (`Unit_UpdateMap(2)`) effects are seams — none
/// change the deterministic unit state this asserts, except as noted.
public struct UnitCombat: Sendable {
    public let movement: UnitMovement
    var actions: UnitActions { movement.actions }
    var scriptInfo: ScriptInfo { movement.scriptInfo }

    public init(movement: UnitMovement) { self.movement = movement }

    /// `Unit_Deviate` (`unit.c:1241`): try to deviate (mind-control) the unit to `houseID`. A normal,
    /// not-already-deviated, deviatable unit deviates with chance `probability`/256 (defaulting to the
    /// owner house's `toughness`, reduced by ⅛ for non-player units). On success: `deviated = 120`,
    /// `deviatedHouse = houseID`, flip to the new owner's default action, and drop all targets. Returns
    /// true iff it deviated. Consumes one `Random256` draw on the eligible path. `Unit_UpdateMap(2)` is a
    /// render seam.
    @discardableResult
    public func deviate(slot: Int, probability prob0: UInt16, houseID: UInt8, in state: inout GameState) -> Bool {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let ui = UnitInfo[ut]
        if !ui.flags.contains(.isNormalUnit) { return false }
        if state.units[slot].deviated != 0 { return false }
        if ui.flags.contains(.isNotDeviatable) { return false }

        var probability = prob0
        if probability == 0 {
            probability = HouseInfo[HouseID(rawValue: Int(state.units[slot].o.houseID)) ?? .harkonnen].toughness
        }
        if state.units[slot].o.houseID != state.playerHouseID { probability -= probability / 8 }

        if UInt16(state.random256.next()) >= probability { return false }

        state.units[slot].deviated = 120
        state.units[slot].deviatedHouse = houseID
        // SEAM: Unit_UpdateMap(2) render redraw.

        let action: UInt8
        if state.playerHouseID == state.units[slot].deviatedHouse {
            action = UInt8(ui.o.actionsPlayer[3].rawValue)
        } else {
            action = UInt8(truncatingIfNeeded: ui.actionAI)
        }
        actions.setAction(slot: slot, action: action, scriptInfo: scriptInfo, in: &state)

        state.unitUntargetMe(slot)
        state.units[slot].targetAttack = 0
        state.units[slot].targetMove = 0
        return true
    }

    /// `Unit_Damage` (`unit.c:1530`): apply `damage` to the unit, returning true iff it died. Drains
    /// hitpoints, wears down deviation, and on death removes the player unit + switches it to `ACTION_DIE`.
    /// Survivors: a small-arms hit on an ambushing enemy provokes `ACTION_ATTACK`; dropping below half HP
    /// turns a sandworm to `ACTION_DIE`, upgrades infantry→trooper-pair (a random chance to `RETREAT`),
    /// and starts smoke on tracked/harvester/wheeled hulls. `range != 0` would spawn an impact explosion
    /// (SEAM).
    @discardableResult
    public func damage(slot: Int, damage: UInt16, range: UInt16, in state: inout GameState) -> Bool {
        guard state.units[slot].o.flags.contains(.allocated) else { return false }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let ui = UnitInfo[ut]
        if !ui.flags.contains(.isNormalUnit) && ut != .sandworm { return false }

        let alive = state.units[slot].o.hitpoints != 0
        _ = alive   // gates only the death-sound feedback (an audio seam)
        if state.units[slot].o.hitpoints >= damage {
            state.units[slot].o.hitpoints &-= damage
        } else {
            state.units[slot].o.hitpoints = 0
        }

        movement.deviationDecrease(slot: slot, amount: 0, in: &state)

        let houseID = state.unitHouseID(state.units[slot])

        if state.units[slot].o.hitpoints == 0 {
            state.unitRemovePlayer(slot)
            // SEAM: harvester death spreads spice (Map_FillCircleWithSpice, Tier-D map).
            // SEAM: Sound_Output_Feedback death cue (audio).
            actions.setAction(slot: slot, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
            return true
        }

        // SEAM: range != 0 → Map_MakeExplosion(IMPACT_SMALL/MEDIUM) at the unit (explosions, #15).

        if houseID != state.playerHouseID
            && state.units[slot].actionID == UInt8(ActionType.ambush.rawValue)
            && ut != .harvester {
            actions.setAction(slot: slot, action: UInt8(ActionType.attack.rawValue), scriptInfo: scriptInfo, in: &state)
        }

        if state.units[slot].o.hitpoints >= ui.o.hitpoints / 2 { return false }

        if ut == .sandworm {
            actions.setAction(slot: slot, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
        }

        if ut == .troopers || ut == .infantry {
            state.units[slot].o.type &+= 2   // infantry→soldier-pair, troopers→trooper-pair
            if let ut2 = UnitType(rawValue: Int(state.units[slot].o.type)) {
                state.units[slot].o.hitpoints = UnitInfo[ut2].o.hitpoints
            }
            // SEAM: Unit_UpdateMap(2) render redraw.
            let toughness = HouseInfo[HouseID(rawValue: Int(state.units[slot].o.houseID)) ?? .harkonnen].toughness
            if UInt16(state.random256.next()) < toughness {
                actions.setAction(slot: slot, action: UInt8(ActionType.retreat.rawValue), scriptInfo: scriptInfo, in: &state)
            }
        }

        // Re-read the (possibly upgraded) type for the hull-smoke check.
        guard let utNow = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let mt = UnitInfo[utNow].movementType
        if mt != .tracked && mt != .harvester && mt != .wheeled { return false }

        state.units[slot].o.flags.insert(.isSmoking)
        state.units[slot].spriteOffset = 0
        state.units[slot].timer = 0
        return false
    }
}
