import DuneIIContracts
import DuneIIWorld

/// `Unit_Damage` + `Map_MakeExplosion` — the impact/explosion cluster, ported as an `extension UnitMovement`
/// (not `UnitCombat`) on purpose: `Unit_Move` (movement) triggers a bullet's explosion, which damages
/// nearby units, which can kill + `Unit_SetAction(DIE)` them — a genuine Move↔Combat cycle in OpenDUNE.
/// Their dependencies (`Unit_Deviation_Decrease`, `Unit_SetAction`, the map/house primitives) all already
/// live on `UnitMovement`, so hosting them here lets `Unit_Move` call them with no construction cycle.
/// `UnitCombat.damage` delegates here so the combat-facing API is unchanged.
///
/// Faithful to OpenDUNE `src/unit.c:1530` (`Unit_Damage`) and `src/map.c:403` (`Map_MakeExplosion`). The
/// `Explosion_Start` animation, `Structure_Damage`/`Structure_HouseUnderAttack`, and `Map_UpdateWall`
/// (wall destruction) are seams — none change the deterministic *unit* state these assert; the structure
/// path needs `Structure_Damage` (not yet ported) and is unreachable for the unit-vs-unit goldens.
extension UnitMovement {
    private static let explosionDeathHand: UInt16 = 11        // EXPLOSION_DEATH_HAND
    private static let explosionSandwormSwallow: UInt16 = 13  // EXPLOSION_SANDWORM_SWALLOW

    /// `Unit_Damage` (`unit.c:1530`): apply `damage` to the unit, returning true iff it died. Drains
    /// hitpoints, wears down deviation, and on death removes the player unit + switches it to `ACTION_DIE`.
    /// Survivors: a small-arms hit on an ambushing enemy provokes `ACTION_ATTACK`; dropping below half HP
    /// turns a sandworm to `ACTION_DIE`, upgrades infantry→trooper-pair (a random chance to `RETREAT`), and
    /// starts smoke on tracked/harvester/wheeled hulls. `range != 0` would spawn an impact explosion (SEAM).
    @discardableResult
    public func damage(slot: Int, damage: UInt16, range: UInt16, in state: inout GameState) -> Bool {
        guard state.units[slot].o.flags.contains(.allocated) else { return false }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let ui = UnitInfo[ut]
        if !ui.flags.contains(.isNormalUnit) && ut != .sandworm { return false }

        if state.units[slot].o.hitpoints >= damage {
            state.units[slot].o.hitpoints &-= damage
        } else {
            state.units[slot].o.hitpoints = 0
        }

        deviationDecrease(slot: slot, amount: 0, in: &state)

        let houseID = state.unitHouseID(state.units[slot])

        if state.units[slot].o.hitpoints == 0 {
            state.unitRemovePlayer(slot)
            // SEAM: harvester death spreads spice (Map_FillCircleWithSpice); Sound_Output_Feedback (audio).
            actions.setAction(slot: slot, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
            return true
        }

        // SEAM: range != 0 → Map_MakeExplosion(IMPACT_SMALL/MEDIUM) at the unit (mapMakeExplosion exists,
        // but the IMPACT_* explosion types + the recursion guard aren't needed by the unit-vs-unit goldens).

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

        guard let utNow = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let mt = UnitInfo[utNow].movementType
        if mt != .tracked && mt != .harvester && mt != .wheeled { return false }

        state.units[slot].o.flags.insert(.isSmoking)
        state.units[slot].spriteOffset = 0
        state.units[slot].timer = 0
        return false
    }

    /// `Map_MakeExplosion` (`map.c:403`): the area effect of an explosion at `position` carrying
    /// `hitpoints` damage, fired by the unit `origin`. Damages every unit within the reaction radius
    /// (`Unit_Damage`, scaled down by distance), and provokes non-allied non-player survivors to retaliate
    /// toward `origin` (team-staging → HUNT, harvesters flee a foot attacker, guards-by-scenario → HUNT,
    /// else `Unit_SetTarget`). Structure damage, wall destruction, and the `Explosion_Start` animation are
    /// seams. `hitpoints == 0` (a pure visual blast) does neither damage nor reactions.
    public func mapMakeExplosion(type: UInt16, position: Tile32, hitpoints: UInt16, origin: UInt16, in state: inout GameState) {
        let reactionDistance: UInt16 = (type == Self.explosionDeathHand) ? 32 : 16
        let positionPacked = position.packed
        let fns = UnitScriptFunctions(unitPrimitives: unit)

        if hitpoints != 0 {
            var find = PoolFind()
            while let u = state.unitFind(&find) {
                guard let uType = UnitType(rawValue: Int(state.units[u].o.type)) else { continue }
                let ui = UnitInfo[uType]

                let distance = Tile32.distance(from: position, to: state.units[u].o.position) >> 4
                if distance >= reactionDistance { continue }

                let isSwallow = (uType == .sandworm && type == Self.explosionSandwormSwallow)
                if !isSwallow && uType != .frigate {
                    damage(slot: u, damage: hitpoints >> (distance >> 2), range: 0, in: &state)
                }

                if state.units[u].o.houseID == state.playerHouseID { continue }

                guard let us = state.indexGetUnit(origin) else { continue }
                if us == u { continue }
                if house.areAllied(state.unitHouseID(state.units[u]), state.unitHouseID(state.units[us]),
                                   playerHouseID: state.playerHouseID) { continue }

                // Team reaction (no team in the unit-vs-unit goldens, but ported faithfully).
                if state.units[u].team != 0 {
                    let t = Int(state.units[u].team) - 1
                    if state.teams[t].action == UInt16(TeamActionType.staging.rawValue) {
                        state.unitRemoveFromTeam(u)
                        actions.setAction(slot: u, action: UInt8(ActionType.hunt.rawValue), scriptInfo: scriptInfo, in: &state)
                        continue
                    }
                    guard let target = state.indexGetUnit(state.teams[t].target),
                          let tType = UnitType(rawValue: Int(state.units[target].o.type)) else { continue }
                    if UnitInfo[tType].bulletType == 0xFF { state.teams[t].target = origin }
                    continue
                }

                if uType == .harvester {
                    if let usType = UnitType(rawValue: Int(state.units[us].o.type)),
                       UnitInfo[usType].movementType == .foot, state.units[u].targetMove == 0 {
                        if state.units[u].actionID != UInt8(ActionType.move.rawValue) {
                            actions.setAction(slot: u, action: UInt8(ActionType.move.rawValue), scriptInfo: scriptInfo, in: &state)
                        }
                        state.units[u].targetMove = origin
                        continue
                    }
                }

                if ui.bulletType == 0xFF { continue }

                if state.units[u].actionID == UInt8(ActionType.guard_.rawValue) && state.units[u].o.flags.contains(.byScenario) {
                    actions.setAction(slot: u, action: UInt8(ActionType.hunt.rawValue), scriptInfo: scriptInfo, in: &state)
                }

                if state.units[u].targetAttack != 0 && state.units[u].actionID != UInt8(ActionType.hunt.rawValue) { continue }

                if state.units[u].targetAttack != 0, state.indexGetUnit(state.units[u].targetAttack) != nil {
                    let packed = state.units[u].o.position.packed
                    if Tile32.distancePacked(state.indexGetTile(state.units[u].targetAttack).packed, packed) <= ui.fireDistance { continue }
                }

                fns.unitSetTarget(slot: u, origin, in: &state)
            }
        }

        // Structure at the impact tile takes the blast. The EXPLOSION_IMPACT_LARGE → SMOKE_PLUME type
        // swap (when the building is already below half HP) is animation-only (SEAM), and
        // Structure_HouseUnderAttack (the AI alert) is a SEAM; the damage itself is ported.
        if hitpoints != 0, let sSlot = state.structureGetByPackedTile(positionPacked) {
            state.structureDamage(sSlot, damage: hitpoints, range: 0)
        }
        // SEAM: wall destruction (Map_UpdateWall) when the impact tile is a wall.

        // The explosion animation (`Explosion_Start`, map.c:512). RNG-free, so this stays golden-neutral
        // and matches the oracle (which also starts — but, like us, doesn't tick — explosions in the
        // scenario harness). The per-tick animation is gated to the lab (`Simulation.tickExplosions`).
        state.explosionStart(type: Int(type), position: position)
    }

    /// `Script_Unit_ExplosionSingle` (op 0x0E, `script/unit.c:533`): one explosion at the unit's position,
    /// of the script-supplied `type`, carrying the unit's full HP as blast damage, attributed to the unit.
    /// The first half of a ground unit's DIE branch (`ExplosionSingle(type)` → `Die`).
    public func explosionSingle(slot: Int, type: UInt16, in state: inout GameState) -> UInt16 {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }
        mapMakeExplosion(type: type, position: state.units[slot].o.position,
                         hitpoints: UnitInfo[ut].o.hitpoints,
                         origin: state.indexEncode(state.units[slot].o.index, type: .unit), in: &state)
        return 0
    }

    /// `Script_Unit_Die` (op 0x0F, `script/unit.c:490`): remove the unit; a saboteur leaves a big blast.
    /// `Unit_Remove` resets the running script in OpenDUNE (so `Script_Run` then stops), which we mirror by
    /// resetting the passed-in `engine` — otherwise the runner keeps executing the freed unit's script this
    /// tick. The `g_scenario` kill/score bookkeeping is a SEAM (not modelled headlessly).
    public func die(slot: Int, engine: inout ScriptEngine, in state: inout GameState) -> UInt16 {
        let position = state.units[slot].o.position
        let isSaboteur = state.units[slot].o.type == UInt8(UnitType.saboteur.rawValue)
        state.unitRemove(slot)   // includes Unit_UntargetMe + Unit_HouseUnitCount_Remove + Script_Reset
        engine.reset()
        if isSaboteur {
            mapMakeExplosion(type: UInt16(ExplosionType.saboteurDeath.rawValue), position: position,
                             hitpoints: 300, origin: 0, in: &state)
        }
        return 0
    }
}
