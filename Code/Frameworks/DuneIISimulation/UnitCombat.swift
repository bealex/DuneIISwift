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

    /// `Unit_Damage` (`unit.c:1530`): apply `damage` to the unit, returning true iff it died. The port
    /// lives on `UnitMovement` (it is also driven by `Unit_Move`'s explosions — see `UnitImpact.swift`);
    /// this is the combat-facing entry point and simply delegates.
    @discardableResult
    public func damage(slot: Int, damage: UInt16, range: UInt16, in state: inout GameState) -> Bool {
        movement.damage(slot: slot, damage: damage, range: range, in: &state)
    }

    // MARK: - Spawning (Unit_Create / Unit_CreateBullet)

    /// `Unit_IsTileOccupied` (`unit.c:1789`): is the unit's current tile blocked for it? True if the
    /// landscape is impassable for its movement type, or an allied/incompatible unit or any structure sits
    /// on it. Sandworms and air units are never blocked. Read-only; composes the map + house primitives.
    public func unitIsTileOccupied(slot: Int, in state: GameState) -> Bool {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return true }
        let ui = UnitInfo[ut]
        let packed = state.units[slot].o.position.packed

        let landscape = movement.map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs)
        if LandscapeInfo[landscape].speed(ui.movementType) == 0 { return true }

        if ut == .sandworm || ui.movementType == .winger { return false }

        if let slot2 = state.unitGetByPackedTile(packed), slot2 != slot {
            if movement.house.areAllied(state.unitHouseID(state.units[slot2]), state.unitHouseID(state.units[slot]),
                                        playerHouseID: state.playerHouseID) { return true }
            if ui.movementType != .tracked { return true }
            if let ut2 = UnitType(rawValue: Int(state.units[slot2].o.type)), UnitInfo[ut2].movementType != .foot { return true }
        }

        return state.structureGetByPackedTile(packed) != nil
    }

    /// `Unit_SetPosition` (`unit.c:1107`): place `slot`'s unit (centred) at `position`. Fails — marking the
    /// unit off-map (`isNotOnMap`) — if the tile is occupied. On success it clears the unit's destination +
    /// targets, refreshes visibility if the tile is unveiled (a fresh-from-factory `seenByHouses` update),
    /// switches it to its default action (AI / harvester / saboteur → `actionAI`, else player action 3), and
    /// stamps it onto the map. Used by the structure deploy/unload natives. Returns whether it was placed.
    @discardableResult
    public func unitSetPosition(slot: Int, position: Tile32, in state: inout GameState) -> Bool {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        let ui = UnitInfo[ut]

        state.units[slot].o.flags.remove(.isNotOnMap)
        state.units[slot].o.position = position.centered

        if state.units[slot].originEncoded == 0 { _ = state.unitFindClosestRefinery(slot) }
        state.units[slot].o.script.variables[4] = 0

        if unitIsTileOccupied(slot: slot, in: state) {
            state.units[slot].o.flags.insert(.isNotOnMap)
            return false
        }

        state.units[slot].currentDestination = Tile32(x: 0, y: 0)
        state.units[slot].targetMove = 0
        state.units[slot].targetAttack = 0

        if state.map[Int(state.units[slot].o.position.packed)].isUnveiled {
            state.units[slot].o.seenByHouses &= ~(UInt8(1) << state.units[slot].o.houseID)
            state.unitHouseUnitCountAdd(slot, houseID: state.playerHouseID)
        }

        let action: UInt8
        if state.units[slot].o.houseID != state.playerHouseID || ut == .harvester || ut == .saboteur {
            action = UInt8(truncatingIfNeeded: ui.actionAI)
        } else {
            action = UInt8(ui.o.actionsPlayer[3].rawValue)
        }
        actions.setAction(slot: slot, action: action, scriptInfo: scriptInfo, in: &state)

        state.units[slot].spriteOffset = 0
        state.unitUpdateMap(1, slot)
        return true
    }

    /// `Unit_CallUnitByType` (`unit.c:2017`): find an idle (`linkedID == 0xFF`, not already moving) unit of
    /// `type`/`houseID` — the *last* one in pool order — and order it to `target` (also storing `target` in
    /// its var-4). With `createCarryall` and none free (and `type == CARRYALL`), spawn a fresh off-map
    /// scenario carryall (placement guards bypassed via `validateStrictIfZero`). Returns the unit slot, or nil.
    @discardableResult
    public func unitCallUnitByType(type: UInt8, houseID: UInt8, target: UInt16,
                                   createCarryall: Bool, in state: inout GameState) -> Int? {
        var found: Int?
        var find = PoolFind(houseID: houseID, type: UInt16(type))
        while let u = state.unitFind(&find) {
            if state.units[u].o.linkedID != 0xFF { continue }
            if state.units[u].targetMove != 0 { continue }
            found = u
        }

        if createCarryall, found == nil, type == UInt8(UnitType.carryall.rawValue) {
            state.validateStrictIfZero &+= 1
            let slot = unitCreate(index: Pool.unitIndexInvalid, type: type, houseID: houseID,
                                  position: Tile32(x: 0, y: 0), orientation: 96, in: &state)
            state.validateStrictIfZero &-= 1
            if let slot { state.units[slot].o.flags.insert(.byScenario); found = slot }
        }

        if let f = found {
            state.units[f].targetMove = target
            state.objectScriptVariable4Set(.unit(f), target)
        }
        return found
    }

    /// `Unit_Create` (`unit.c:1380`): allocate + fully initialize a unit of `type` for `houseID` at
    /// `position` facing `orientation`, and (if on-map) place it and switch it to its default action.
    /// `index` is the desired slot or `Pool.unitIndexInvalid` for any free one. Returns the new slot, or
    /// `nil` if allocation fails or the destination tile is occupied. A `0xFFFF:0xFFFF` position creates an
    /// off-map (`isNotOnMap`) unit. The map-redraw seams are inherited from `unitUpdateMap`/`setAction`.
    @discardableResult
    public func unitCreate(index: UInt16, type: UInt8, houseID: UInt8,
                           position: Tile32, orientation: Int8, in state: inout GameState) -> Int? {
        if houseID >= 6 { return nil }                                  // HOUSE_MAX
        guard let ut = UnitType(rawValue: Int(type)) else { return nil }  // typeID >= UNIT_MAX
        let ui = UnitInfo[ut]

        guard let slot = state.unitAllocate(index: index, type: type, houseID: houseID) else { return nil }
        state.units[slot].o.houseID = houseID

        var u = state.units[slot]
        movement.unit.setOrientation(&u, orientation: orientation, rotateInstantly: true, level: 0)
        movement.unit.setOrientation(&u, orientation: orientation, rotateInstantly: true, level: 1)
        movement.unit.setSpeed(&u, speed: 0, gameSpeed: state.gameSpeed)
        state.units[slot] = u

        state.units[slot].o.position = position
        state.units[slot].o.hitpoints = ui.o.hitpoints
        state.units[slot].currentDestination = Tile32(x: 0, y: 0)
        state.units[slot].originEncoded = 0
        state.units[slot].route[0] = 0xFF

        let onMap = position.x != 0xFFFF || position.y != 0xFFFF
        if onMap {
            // Unit_FindClosestRefinery sets originEncoded internally, but Unit_Create overwrites it with
            // the function's return (`res`, 0/1) — faithful to OpenDUNE's `= Unit_FindClosestRefinery(u)`.
            let origin = state.unitFindClosestRefinery(slot)
            state.units[slot].originEncoded = origin
            state.units[slot].targetLast = position
            state.units[slot].targetPreLast = position
        }

        state.units[slot].o.linkedID = 0xFF
        state.units[slot].o.script.delay = 0
        state.units[slot].actionID = UInt8(ActionType.guard_.rawValue)
        state.units[slot].nextActionID = 0xFF   // ACTION_INVALID
        state.units[slot].fireDelay = 0
        state.units[slot].distanceToDestination = 0x7FFF
        state.units[slot].targetMove = 0
        state.units[slot].amount = 0
        state.units[slot].wobbleIndex = 0
        state.units[slot].spriteOffset = 0
        state.units[slot].blinkCounter = 0
        state.units[slot].timer = 0

        state.units[slot].o.script.reset()   // Script_Reset(&u->o.script, g_scriptUnit)
        state.units[slot].o.flags.insert(.allocated)

        if ui.movementType == .tracked {
            let chance = HouseInfo[HouseID(rawValue: Int(houseID)) ?? .harkonnen].degradingChance
            if UInt16(state.random256.next()) < chance { state.units[slot].o.flags.insert(.degrades) }
        }

        if ui.movementType == .winger {
            var u2 = state.units[slot]
            movement.unit.setSpeed(&u2, speed: 255, gameSpeed: state.gameSpeed)
            state.units[slot] = u2
        } else if onMap && unitIsTileOccupied(slot: slot, in: state) {
            state.unitFree(slot)
            return nil
        }

        if !onMap {
            state.units[slot].o.flags.insert(.isNotOnMap)
            return slot
        }

        state.unitUpdateMap(1, slot)

        let action = houseID == state.playerHouseID ? UInt8(ui.o.actionsPlayer[3].rawValue)
                                                    : UInt8(truncatingIfNeeded: ui.actionAI)
        actions.setAction(slot: slot, action: action, scriptInfo: scriptInfo, in: &state)
        return slot
    }

    /// `Unit_CreateBullet` (`unit.c:1310`): spawn a projectile of `type` from `position` toward `target`,
    /// owned by `houseID`, carrying `damage`. Missiles spawn at the firing tile and may scatter
    /// (`notAccurate`); a bullet/sonic-blast spawns one tile ahead along the line of fire and is "big" when
    /// `damage > 15`. Returns the bullet's slot, or `nil` on an invalid target / allocation failure. The
    /// `Voice_PlayAtTile` cue is an audio seam; the unseen-bullet `Tile_RemoveFogInRadius` is ported.
    @discardableResult
    public func unitCreateBullet(position: Tile32, type: UInt8, houseID: UInt8, damage: UInt16,
                                 target: UInt16, in state: inout GameState) -> Int? {
        if !state.indexIsValid(target) { return nil }
        guard let ut = UnitType(rawValue: Int(type)) else { return nil }
        let ui = UnitInfo[ut]
        let tile = state.indexGetTile(target)

        switch ut {
            case .missileHouse, .missileRocket, .missileTurret, .missileDeviator, .missileTrooper:
                let orientation = Tile32.direction(from: position, to: tile)
                guard let bullet = unitCreate(index: Pool.unitIndexInvalid, type: type, houseID: houseID,
                                              position: position, orientation: orientation, in: &state) else { return nil }
                // SEAM: Voice_PlayAtTile(bulletSound) audio.
                state.units[bullet].targetAttack = target
                state.units[bullet].o.hitpoints = damage
                state.units[bullet].currentDestination = tile

                if ui.flags.contains(.notAccurate) {
                    let scatter: UInt16 = (state.random256.next() & 0xF) != 0
                        ? Tile32.distance(from: position, to: tile) / 256 + 8
                        : UInt16(state.random256.next()) + 8
                    state.units[bullet].currentDestination = Tile32.moveByRandom(tile, distance: scatter, center: false, rng: &state.random256)
                }

                state.units[bullet].fireDelay = ui.fireDistance & 0xFF
                if let u = state.indexGetUnit(target), let ut2 = UnitType(rawValue: Int(state.units[u].o.type)),
                   UnitInfo[ut2].movementType == .winger {
                    state.units[bullet].fireDelay <<= 1
                }

                if ut == .missileHouse || (state.units[bullet].o.seenByHouses & (1 << state.playerHouseID)) != 0 { return bullet }
                state.tileRemoveFogInRadius(state.units[bullet].o.position, radius: 2)
                return bullet

            case .bullet, .sonicBlast:
                let orientation = Tile32.direction(from: position, to: tile)
                let t = Tile32.moveByDirection(Tile32.moveByDirection(position, orientation: 0, distance: 32),
                                               orientation: Int16(orientation), distance: 128)
                guard let bullet = unitCreate(index: Pool.unitIndexInvalid, type: type, houseID: houseID,
                                              position: t, orientation: orientation, in: &state) else { return nil }
                if ut == .sonicBlast { state.units[bullet].fireDelay = ui.fireDistance & 0xFF }
                state.units[bullet].currentDestination = tile
                state.units[bullet].o.hitpoints = damage
                if damage > 15 { state.units[bullet].o.flags.insert(.bulletIsBig) }

                if (state.units[bullet].o.seenByHouses & (1 << state.playerHouseID)) != 0 { return bullet }
                state.tileRemoveFogInRadius(state.units[bullet].o.position, radius: 2)
                return bullet

            default: return nil
        }
    }

    // MARK: - Script_Unit_Fire (native 0x08)

    /// `Script_Unit_Fire` (`script/unit.c:577`, native `0x08`): fire the unit's weapon at `targetAttack`.
    /// Faithful transcription: the early-outs (no/invalid target, self-target, still turning, retarget,
    /// fireDelay, out of range, off-aim), then `Unit_CreateBullet` (or the sandworm devour), then the
    /// post-fire `fireDelay` (with the `firesTwice` 2nd-shot short delay + the `Random256 & 1` jitter).
    /// Returns 1 if it fired, 0 otherwise. `Map_MakeExplosion` (sandworm) + the audio cues are seams.
    @discardableResult
    public func fire(slot: Int, in state: inout GameState) -> UInt16 {
        let target = state.units[slot].targetAttack
        if target == 0 || !state.indexIsValid(target) { return 0 }

        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }
        let ui = UnitInfo[ut]
        let fns = UnitScriptFunctions(unitPrimitives: movement.unit)
        let aimLevel = ui.o.flags.contains(.hasTurret) ? 1 : 0

        if ut != .sandworm && target == state.indexEncode(state.units[slot].o.position.packed, type: .tile) {
            state.units[slot].targetAttack = 0
        }
        if state.units[slot].targetAttack != target {
            fns.unitSetTarget(slot: slot, target, in: &state)
            return 0
        }

        if ut != .sandworm && state.units[slot].orientation[aimLevel].speed != 0 { return 0 }

        if Tools.indexType(target) == .tile {
            let packed = Tools.indexDecode(target)
            if state.unitGetByPackedTile(packed) != nil || state.structureGetByPackedTile(packed) != nil {
                fns.unitSetTarget(slot: slot, target, in: &state)
            }
        }

        if state.units[slot].fireDelay != 0 { return 0 }

        let distance = GeneralScriptFunctions().getDistanceToObject(from: state.units[slot].o.position, encoded: target, in: state)
        if Int16(truncatingIfNeeded: Int(ui.fireDistance) << 8) < Int16(bitPattern: distance) { return 0 }

        let targetIsWinger: Bool = state.indexGetUnit(target).flatMap { UnitType(rawValue: Int(state.units[$0].o.type)) }
            .map { UnitInfo[$0].movementType == .winger } ?? false
        if ut != .sandworm && (Tools.indexType(target) != .unit || !targetIsWinger) {
            let orientation = Tile32.direction(from: state.units[slot].o.position, to: state.indexGetTile(target))
            var diff = abs(Int(state.units[slot].orientation[aimLevel].current) - Int(orientation))
            if ui.movementType == .winger { diff /= 8 }
            if diff >= 8 { return 0 }
        }

        var damage = ui.damage
        var typeID = ui.bulletType
        let fireTwice = ui.flags.contains(.firesTwice) && state.units[slot].o.hitpoints > ui.o.hitpoints / 2
        if (ut == .troopers || ut == .trooper) && Int16(bitPattern: distance) > 512 {
            typeID = UInt8(UnitType.missileTrooper.rawValue)
        }

        switch UnitType(rawValue: Int(typeID)) {
            case .sandworm:
                state.unitUpdateMap(0, slot)
                if let target2 = state.indexGetUnit(target) {
                    state.units[target2].o.script.variables[1] = 0xFFFF
                    state.unitRemove(target2)   // Unit_RemovePlayer + HouseUnitCount_Remove are folded into unitRemove
                }
                // SEAM: Map_MakeExplosion(ui.explosionType, position) (#15) + Voice_PlayAtTile.
                state.unitUpdateMap(1, slot)
                state.units[slot].amount &-= 1
                state.units[slot].o.script.delay = 12
                if Int8(bitPattern: UInt8(truncatingIfNeeded: state.units[slot].amount)) < 1 {
                    actions.setAction(slot: slot, action: UInt8(ActionType.die.rawValue), scriptInfo: scriptInfo, in: &state)
                }

            case .missileTrooper, .missileRocket, .missileTurret, .missileDeviator, .bullet, .sonicBlast:
                if UnitType(rawValue: Int(typeID)) == .missileTrooper { damage -= damage / 4 }
                guard let bullet = unitCreateBullet(position: state.units[slot].o.position, type: typeID,
                                                    houseID: state.unitHouseID(state.units[slot]),
                                                    damage: damage, target: target, in: &state) else { return 0 }
                state.units[bullet].originEncoded = state.indexEncode(state.units[slot].o.index, type: .unit)
                // SEAM: Voice_PlayAtTile(bulletSound) audio.
                movement.deviationDecrease(slot: slot, amount: 20, in: &state)

            default: break
        }

        state.units[slot].fireDelay = Tools.adjustToGameSpeed(normal: ui.fireDelay &* 2, minimum: 1, maximum: 0xFFFF,
                                                              inverseSpeed: true, gameSpeed: state.gameSpeed)
        if fireTwice {
            if state.units[slot].o.flags.contains(.fireTwiceFlip) { state.units[slot].o.flags.remove(.fireTwiceFlip) }
            else { state.units[slot].o.flags.insert(.fireTwiceFlip) }
            if state.units[slot].o.flags.contains(.fireTwiceFlip) {
                state.units[slot].fireDelay = Tools.adjustToGameSpeed(normal: 5, minimum: 1, maximum: 10,
                                                                      inverseSpeed: true, gameSpeed: state.gameSpeed)
            }
        } else {
            state.units[slot].o.flags.remove(.fireTwiceFlip)
        }

        state.units[slot].fireDelay &+= UInt16(state.random256.next() & 1)
        state.unitUpdateMap(2, slot)
        return 1
    }
}
