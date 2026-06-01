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
    /// starts smoke on tracked/harvester/wheeled hulls. `range != 0` leaves a visual impact crater.
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
            if ut == .harvester {   // a dying harvester spills its load as spice
                map.fillCircleWithSpice(state.units[slot].o.position.packed,
                                        radius: UInt16(state.units[slot].amount) / 32, in: &state)
            }
            // SEAM: Sound_Output_Feedback death cue (audio).
            actions.setAction(slot: slot, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
            return true
        }

        // A ranged hit leaves a visual impact crater at the unit (hitpoints 0 ⇒ no further damage/reactions,
        // so no recursion). IMPACT_SMALL for light hits, IMPACT_MEDIUM otherwise.
        if range != 0 {
            mapMakeExplosion(type: UInt16(damage < 25 ? ExplosionType.impactSmall.rawValue : ExplosionType.impactMedium.rawValue),
                             position: state.units[slot].o.position, hitpoints: 0, origin: 0, in: &state)
        }

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

    /// `Unit_Deviate` (`unit.c:1241`): try to deviate (mind-control) the unit to `houseID`. A normal,
    /// not-already-deviated, deviatable unit deviates with chance `probability`/256 (defaulting to the
    /// owner house's `toughness`, reduced by ⅛ for non-player units). On success: `deviated = 120`,
    /// `deviatedHouse = houseID`, flip to the new owner's default action, and drop all targets. Returns
    /// true iff it deviated. Consumes one `Random256` draw on the eligible path. `Unit_UpdateMap(2)` is a
    /// render seam. Hosted here (not `UnitCombat`) so `Map_DeviateArea`'s `Unit_Move` caller can reach it.
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

    /// `Map_DeviateArea` (`map.c:642`): a deviator missile's gas cloud. Starts the `type` explosion at
    /// `position`, then deviates every unit within `radius` tiles to `houseID` (probability 0 ⇒ each
    /// unit's owner toughness). Each eligible unit costs one `Random256` draw — gated off the goldens
    /// (no deviator missile appears in them).
    public func mapDeviateArea(type: UInt16, position: Tile32, radius: UInt16, houseID: UInt8, in state: inout GameState) {
        state.explosionStart(type: Int(type), position: position)
        var find = PoolFind()
        while let u = state.unitFind(&find) {
            if Tile32.distance(from: position, to: state.units[u].o.position) / 16 >= radius { continue }
            deviate(slot: u, probability: 0, houseID: houseID, in: &state)
        }
    }

    /// `Map_Bloom_ExplodeSpice` (`map.c:669`): detonate a spice bloom at `packed`. Removes the unit on the
    /// bloom tile, reverts the ground to its base tile, fires the (cosmetic) tremor explosion, and spreads
    /// spice in a radius-5 circle. The `Sound_Output_Feedback` cue is an audio SEAM. `Map_FillCircleWithSpice`
    /// draws RNG (the radius-edge half-skip) — no bloom tile appears in the goldens, so it stays neutral.
    /// (`Map_Bloom_ExplodeSpecial`, `map.c:833`, is unreachable in 1.07 — `isSpecialBloom` is never set.)
    public func mapBloomExplodeSpice(packed: UInt16, houseID: UInt8, in state: inout GameState) {
        if state.validateStrictIfZero == 0 {
            if let u = state.unitGetByPackedTile(packed) { state.unitRemove(u) }
            state.map[Int(packed)].groundTileID = state.mapBaseTileID[Int(packed)] & 0x1FF
            mapMakeExplosion(type: UInt16(ExplosionType.spiceBloomTremor.rawValue),
                             position: Tile32.unpack(packed), hitpoints: 0, origin: 0, in: &state)
        }
        // SEAM: Sound_Output_Feedback(36) for the player house (audio).
        map.fillCircleWithSpice(packed, radius: 5, in: &state)
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
        // swap (when the building is already below half HP) is animation-only (SEAM). The
        // Structure_HouseUnderAttack alert (`map.c:500`) fires here — on real combat impact only — so the
        // "base under attack" warning never triggers on degradation/power/placement HP changes.
        if hitpoints != 0, let sSlot = state.structureGetByPackedTile(positionPacked) {
            state.structureHouseUnderAttack(state.structures[sSlot].o.houseID)
            state.structureDamage(sSlot, damage: hitpoints, range: 0)
        }
        // Wall destruction (`map.c:503`): a wall tile is destroyed if the blast HP is at least the wall's
        // HP (deterministic — the `||` short-circuits, drawing no RNG) or a probabilistic Random_256 roll.
        if hitpoints != 0, map.landscapeType(state.map[Int(positionPacked)], tileIDs: state.tileIDs) == .wall {
            let wallHP = Int(StructureInfo[.wall].o.hitpoints)
            if wallHP <= Int(hitpoints) || Int(state.random256.next()) <= Int(hitpoints) * 256 / wallHP {
                state.mapUpdateWall(positionPacked)
            }
        }

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
    /// tick. Updates the `g_scenario` kill/score tally (a non-winger kill is worth `max(buildCredits/100, 1)`).
    public func die(slot: Int, engine: inout ScriptEngine, in state: inout GameState) -> UInt16 {
        let position = state.units[slot].o.position
        let isSaboteur = state.units[slot].o.type == UInt8(UnitType.saboteur.rawValue)
        // Kill tally (`script/unit.c:502`): non-winger only; the player's losses subtract from the score.
        if let ut = UnitType(rawValue: Int(state.units[slot].o.type)), UnitInfo[ut].movementType != .winger {
            let credits = max(UnitInfo[ut].o.buildCredits / 100, 1)
            if state.units[slot].o.houseID == state.playerHouseID {
                state.scenario.killedAllied &+= 1; state.scenario.score &-= credits
            } else {
                state.scenario.killedEnemy &+= 1; state.scenario.score &+= credits
            }
        }
        state.unitRemove(slot)   // includes Unit_UntargetMe + Unit_HouseUnitCount_Remove + Script_Reset
        engine.reset()
        if isSaboteur {
            mapMakeExplosion(type: UInt16(ExplosionType.saboteurDeath.rawValue), position: position,
                             hitpoints: 300, origin: 0, in: &state)
        }
        return 0
    }

    /// `Script_Unit_Harvest` (op 0x2A, `script/unit.c:1652`): a harvester sitting on spice gathers. Adds a
    /// random 0/1 to `amount` (capped at 100), flags `inTransport`, and ~1/32 of the time depletes the
    /// tile's spice. Returns 1 while still gathering, 0 when full / off-spice / not a harvester. Two
    /// `Random256` draws (the `& 1` fill, then the `& 0x1F` deplete gate) — order matches the oracle.
    public func harvest(slot: Int, in state: inout GameState) -> UInt16 {
        guard state.units[slot].o.type == UInt8(UnitType.harvester.rawValue) else { return 0 }
        if state.units[slot].amount >= 100 { return 0 }
        let packed = state.units[slot].o.position.packed
        let type = map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
        if type != .spice && type != .thickSpice { return 0 }

        state.units[slot].amount &+= UInt8(state.random256.next() & 1)
        state.units[slot].o.flags.insert(.inTransport)
        // SEAM: Unit_UpdateMap(2) render redraw.
        if state.units[slot].amount > 100 { state.units[slot].amount = 100 }

        if state.random256.next() & 0x1F != 0 { return 1 }
        map.changeSpiceAmount(packed, -1, in: &state)
        return 0
    }

    /// `Script_General_SearchSpice` (op 0x29, `script/general.c:325`): the nearest harvestable spice tile
    /// within `radius` of the unit, encoded as a tile index (0 if none found).
    public func searchSpice(slot: Int, radius: UInt16, in state: GameState) -> UInt16 {
        let spice = map.searchSpice(state.units[slot].o.position.packed, radius: radius, in: state)
        return spice == 0 ? 0 : state.indexEncode(spice, type: .tile)
    }

    /// `Script_Unit_MoveToTarget` (op 0x16, `script/unit.c:427`): home the unit onto its `targetMove` tile.
    /// **Far** (≥128 sub-units): face the target + set a distance/turn-scaled speed. **Close** (<128): stop
    /// and step ±16/axis toward it — arrived (<32) returns 1, otherwise it re-runs (rewind the script PC by
    /// one word + a short `delay`) to keep closing. The aircraft/bullet fine-approach. RNG-free; the
    /// `Unit_UpdateMap(2)` render redraw is a SEAM.
    public func moveToTarget(slot: Int, engine: inout ScriptEngine, in state: inout GameState) -> UInt16 {
        if state.units[slot].targetMove == 0 { return 0 }
        let tile = state.indexGetTile(state.units[slot].targetMove)
        let distance = Tile32.distance(from: state.units[slot].o.position, to: tile)
        var u = state.units[slot]

        if Int16(bitPattern: distance) < 128 {
            unit.setSpeed(&u, speed: 0, gameSpeed: state.gameSpeed)
            let dx = Int(Int16(bitPattern: tile.x &- u.o.position.x))
            let dy = Int(Int16(bitPattern: tile.y &- u.o.position.y))
            u.o.position.x = u.o.position.x &+ UInt16(bitPattern: Int16(max(-16, min(16, dx))))
            u.o.position.y = u.o.position.y &+ UInt16(bitPattern: Int16(max(-16, min(16, dy))))
            state.units[slot] = u
            // SEAM: Unit_UpdateMap(2) render redraw.
            if Int16(bitPattern: distance) < 32 { return 1 }
            engine.delay = 2
            engine.scriptPC &-= 1                                       // re-run this opcode next time (Script_Run: script->script--)
            return 0
        }

        let orientation = Tile32.direction(from: u.o.position, to: tile)
        unit.setOrientation(&u, orientation: orientation, rotateInstantly: false, level: 0)
        var diff = abs(Int(orientation) - Int(u.orientation[0].current))
        if diff > 128 { diff = 256 - diff }
        let speed = (max(min(Int(distance) / 8, 255), 25) * (255 - diff) + 128) / 256
        unit.setSpeed(&u, speed: UInt16(truncatingIfNeeded: speed), gameSpeed: state.gameSpeed)
        state.units[slot] = u
        // SEAM: Unit_UpdateMap(2) render redraw.
        engine.delay = UInt16(max(Int(Int16(bitPattern: distance)) / 1024, 1))
        engine.scriptPC &-= 1
        return 0
    }

    /// `Script_Unit_ExplosionMultiple` (op 0x12, `script/unit.c:553`): the death-hand's 8 blasts — one
    /// `EXPLOSION_DEATH_HAND` at the unit (25…50 dmg) + 7 at random offsets within `radius` (75…150 dmg).
    /// Each iteration draws `Tile_MoveByRandom` (2× `Random256`) then `RandomLCG_Range` (the source
    /// argument order; C's arg-eval order is compiler-defined and this path isn't golden-pinned).
    public func explosionMultiple(slot: Int, radius: UInt16, in state: inout GameState) -> UInt16 {
        let pos = state.units[slot].o.position
        mapMakeExplosion(type: UInt16(ExplosionType.deathHand.rawValue), position: pos,
                         hitpoints: state.randomLCG.range(25, 50), origin: 0, in: &state)
        for _ in 0 ..< 7 {
            let p = Tile32.moveByRandom(pos, distance: radius, center: false, rng: &state.random256)
            let hp = state.randomLCG.range(75, 150)
            mapMakeExplosion(type: UInt16(ExplosionType.deathHand.rawValue), position: p,
                             hitpoints: hp, origin: 0, in: &state)
        }
        return 0
    }
}
