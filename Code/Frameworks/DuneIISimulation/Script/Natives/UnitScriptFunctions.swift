import DuneIIContracts
import DuneIIWorld

/// The unit-category EMC native script functions (`Script_Unit_*`, `src/script/unit.c`), op-14 targets
/// for unit scripts. Clean explicit-parameter functions (the stack handling lives in the VM glue);
/// each operates on the running unit by pool `slot`. Mutating natives go through the injected
/// `UnitPrimitives` (so `Unit_SetSpeed`/`Unit_SetOrientation` stay the single replaceable port).
public struct UnitScriptFunctions: Sendable {
    public let unitPrimitives: any UnitPrimitives

    public init(unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives()) {
        self.unitPrimitives = unitPrimitives
    }

    /// `Script_Unit_GetInfo`: read one of the running unit's many info `field`s (the big switch in
    /// `src/script/unit.c`). Mostly pure reads; field `0x06` lazily resolves the harvester's origin
    /// refinery (mutating `originEncoded`), so this takes `inout` state.
    public func getInfo(slot: Int, field: UInt16, in state: inout GameState) -> UInt16 {
        let u = state.units[slot]
        guard let utype = UnitType(rawValue: Int(u.o.type)) else { return 0 }

        let ui = UnitInfo[utype]

        switch field {
            case 0x00: return UInt16(UInt32(u.o.hitpoints) * 256 / UInt32(ui.o.hitpoints))  // %HP × 256
            case 0x01: return state.indexIsValid(u.targetMove) ? u.targetMove : 0
            case 0x02: return ui.fireDistance << 8
            case 0x03: return u.o.index
            case 0x04: return UInt16(bitPattern: Int16(u.orientation[0].current))
            case 0x05: return u.targetAttack
            case 0x06:
                if u.originEncoded == 0 || utype == .harvester { state.unitFindClosestRefinery(slot) }
                return state.units[slot].originEncoded
            case 0x07: return UInt16(u.o.type)
            case 0x08: return state.indexEncode(u.o.index, type: .unit)
            case 0x09: return UInt16(u.movingSpeed)
            case 0x0A: return UInt16(abs(Int(u.orientation[0].target) - Int(u.orientation[0].current)))
            case 0x0B: return (u.currentDestination.x == 0 && u.currentDestination.y == 0) ? 0 : 1
            case 0x0C: return u.fireDelay == 0 ? 1 : 0
            case 0x0D: return ui.flags.contains(.explodeOnDeath) ? 1 : 0
            case 0x0E: return UInt16(state.unitHouseID(u))
            case 0x0F: return u.o.flags.contains(.byScenario) ? 1 : 0
            case 0x10:
                let idx = ui.o.flags.contains(.hasTurret) ? 1 : 0
                return UInt16(bitPattern: Int16(u.orientation[idx].current))
            case 0x11:
                let idx = ui.o.flags.contains(.hasTurret) ? 1 : 0
                return UInt16(abs(Int(u.orientation[idx].target) - Int(u.orientation[idx].current)))
            case 0x12: return (UInt8(ui.movementType.rawValue) & 0x40) == 0 ? 0 : 1  // always 0 in 1.07
            case 0x13: return (u.o.seenByHouses & (1 << state.playerHouseID)) == 0 ? 0 : 1
            default: return 0
        }
    }

    /// `Script_Unit_GetAmount`: the running unit's `amount`, or its linked unit's amount if linked.
    public func getAmount(_ unit: Unit, in state: GameState) -> UInt16 {
        if unit.o.linkedID == 0xFF { return UInt16(unit.amount) }
        return UInt16(state.units[Int(unit.o.linkedID)].amount)
    }

    /// `Script_Unit_GetOrientation`: the direction from the unit to the tile `encoded` points at, or its
    /// own base orientation when `encoded` is invalid.
    public func getOrientation(_ unit: Unit, encoded: UInt16, in state: GameState) -> UInt16 {
        let dir: Int8 = state.indexIsValid(encoded)
            ? Tile32.direction(from: unit.o.position, to: state.indexGetTile(encoded))
            : unit.orientation[0].current
        return UInt16(bitPattern: Int16(dir))
    }

    /// `Script_Unit_SetSpeed`: clamp the requested speed to 0…255, scale by 192/256 unless the unit was
    /// scenario-placed, apply via `Unit_SetSpeed`, and return the resulting per-tick `speed`.
    public func setSpeed(slot: Int, requestedSpeed: UInt16, in state: inout GameState) -> UInt16 {
        var speed = min(requestedSpeed, 255)
        if !state.units[slot].o.flags.contains(.byScenario) { speed = speed * 192 / 256 }
        unitPrimitives.setSpeed(&state.units[slot], speed: speed, gameSpeed: state.gameSpeed)
        return UInt16(state.units[slot].speed)
    }

    /// `Script_Unit_SetOrientation`: aim the body at `orientation`; returns the (new) current orientation.
    public func setOrientation(slot: Int, orientation: Int8, in state: inout GameState) -> UInt16 {
        unitPrimitives.setOrientation(&state.units[slot], orientation: orientation, rotateInstantly: false, level: 0)
        return UInt16(bitPattern: Int16(state.units[slot].orientation[0].current))
    }

    /// `Script_Unit_Rotate`: begin rotating the turret (or body) toward `targetAttack`. Returns 1 if it
    /// is busy/started rotating, 0 if there's nothing to do.
    public func rotate(slot: Int, in state: inout GameState) -> UInt16 {
        let u = state.units[slot]
        guard let ut = UnitType(rawValue: Int(u.o.type)) else { return 0 }

        let ui = UnitInfo[ut]
        if ui.movementType != .winger && (u.currentDestination.x != 0 || u.currentDestination.y != 0) { return 1 }

        let index = ui.o.flags.contains(.hasTurret) ? 1 : 0
        if u.orientation[index].speed != 0 { return 1 }  // already rotating
        if !state.indexIsValid(u.targetAttack) { return 0 }

        let orientation = Tile32.direction(from: u.o.position, to: state.indexGetTile(u.targetAttack))
        if orientation == u.orientation[index].current { return 0 }  // already aimed
        unitPrimitives.setOrientation(
            &state.units[slot],
            orientation: orientation,
            rotateInstantly: false,
            level: index
        )
        return 1
    }

    /// `Script_Unit_Stop`: halt the unit and refresh its map presence. Returns 0.
    public func stop(slot: Int, in state: inout GameState) -> UInt16 {
        unitPrimitives.setSpeed(&state.units[slot], speed: 0, gameSpeed: state.gameSpeed)
        state.unitUpdateMap(2, slot)
        return 0
    }

    /// `Script_Unit_IsInTransport`: 1 if the unit is loaded in a transport.
    public func isInTransport(_ unit: Unit) -> UInt16 {
        unit.o.flags.contains(.inTransport) ? 1 : 0
    }

    /// `Script_Unit_GetRandomTile`: a random tile within ~80 of the unit (mutating the RNG), encoded as
    /// a tile index — but only when `encoded` is itself a tile index, else 0.
    public func getRandomTile(slot: Int, encoded: UInt16, in state: inout GameState) -> UInt16 {
        if Tools.indexType(encoded) != .tile { return 0 }
        let tile = Tile32.moveByRandom(
            state.units[slot].o.position,
            distance: 80,
            center: true,
            rng: &state.random256
        )
        return state.indexEncode(tile.packed, type: .tile)
    }

    /// `Script_Unit_SetTarget`: set the attack target and aim at it. A turretless unit also moves toward
    /// it. Clearing (target 0 / invalid) zeroes `targetAttack`. Returns the new `targetAttack`.
    public func setTarget(slot: Int, target: UInt16, in state: inout GameState) -> UInt16 {
        if target == 0 || !state.indexIsValid(target) {
            state.units[slot].targetAttack = 0
            return 0
        }
        let orientation = Tile32.direction(from: state.units[slot].o.position, to: state.indexGetTile(target))
        state.units[slot].targetAttack = target
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return target }

        if !UnitInfo[ut].o.flags.contains(.hasTurret) {
            state.units[slot].targetMove = target
            unitPrimitives.setOrientation(
                &state.units[slot],
                orientation: orientation,
                rotateInstantly: false,
                level: 0
            )
        }
        unitPrimitives.setOrientation(&state.units[slot], orientation: orientation, rotateInstantly: false, level: 1)
        return state.units[slot].targetAttack
    }

    /// `Script_Unit_SetDestinationDirect`: point the unit's `currentDestination` at `encoded` (only if it
    /// has none yet, or it's a normal unit) and aim the body there. Returns 0.
    public func setDestinationDirect(slot: Int, encoded: UInt16, in state: inout GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return 0 }
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }

        let dest = state.units[slot].currentDestination
        if (dest.x == 0 && dest.y == 0) || UnitInfo[ut].flags.contains(.isNormalUnit) {
            state.units[slot].currentDestination = state.indexGetTile(encoded)
        }
        let dir = Tile32.direction(from: state.units[slot].o.position, to: state.units[slot].currentDestination)
        unitPrimitives.setOrientation(&state.units[slot], orientation: dir, rotateInstantly: false, level: 0)
        return 0
    }

    /// `Unit_SetDestination` (`unit.c:701`): the shared move-target primitive — set the unit's
    /// `targetMove`, resolving a *tile* index that holds a unit/structure to that object, and linking
    /// script-var-4 when moving into a friendly enterable structure. No-op if the index is invalid or the
    /// target is unchanged. Used by `Script_Unit_SetDestination` (below) and the player-order path
    /// (`UnitOrders`), which delegates here so the primitive has a single home.
    public func unitSetDestination(slot: Int, _ destination0: UInt16, in state: inout GameState) {
        var destination = destination0
        if !state.indexIsValid(destination) { return }
        if state.units[slot].targetMove == destination { return }

        if Tools.indexType(destination) == .tile {
            let packed = Tools.indexDecode(destination)
            if let u2 = state.unitGetByPackedTile(packed) {
                if u2 != slot { destination = state.indexEncode(state.units[u2].o.index, type: .unit) }
            } else if let s = state.structureGetByPackedTile(packed) {
                destination = state.indexEncode(state.structures[s].o.index, type: .structure)
            }
        }

        if let sSlot = state.indexGetStructure(destination),
                state.structures[sSlot].o.houseID == state.unitHouseID(state.units[slot]),
                let ut = UnitType(rawValue: Int(state.units[slot].o.type)) {
            let valid = unitPrimitives.isValidMovementIntoStructure(
                state.units[slot],
                state.structures[sSlot],
                in: state
            )
            if valid == 1 || UnitInfo[ut].movementType == .winger {
                state.objectScriptVariable4Link(state.indexEncode(state.units[slot].o.index, type: .unit), destination)
            }
        }

        state.units[slot].targetMove = destination
        state.units[slot].route[0] = 0xFF
    }

    /// `Unit_SetTarget` (`unit.c:621`): the shared attack-target primitive — set the unit's `targetAttack`,
    /// resolving a *tile* index that holds a unit/structure to that object, mapping a self-target to the
    /// unit's own tile, and (for a turretless unit) also driving `targetMove`. No-op if invalid/unchanged.
    /// Used by `Script_Unit_Fire` and the player-order path (`UnitOrders.setTarget`, which delegates here).
    public func unitSetTarget(slot: Int, _ encoded0: UInt16, in state: inout GameState) {
        var encoded = encoded0
        if !state.indexIsValid(encoded) { return }
        if state.units[slot].targetAttack == encoded { return }

        if Tools.indexType(encoded) == .tile {
            let packed = Tools.indexDecode(encoded)
            if let u = state.unitGetByPackedTile(packed) {
                encoded = state.indexEncode(state.units[u].o.index, type: .unit)
            } else if let s = state.structureGetByPackedTile(packed) {
                encoded = state.indexEncode(state.structures[s].o.index, type: .structure)
            }
        }

        if state.indexEncode(state.units[slot].o.index, type: .unit) == encoded {
            encoded = state.indexEncode(state.units[slot].o.position.packed, type: .tile)
        }

        state.units[slot].targetAttack = encoded
        if let ut = UnitType(rawValue: Int(state.units[slot].o.type)), !UnitInfo[ut].o.flags.contains(.hasTurret) {
            state.units[slot].targetMove = encoded
            state.units[slot].route[0] = 0xFF
        }
    }

    /// `Script_Unit_SetDestination` (`script/unit.c:796`, native `0x05`): set the running unit's move
    /// destination from the stack arg. A `0` / invalid index just clears `targetMove`. A harvester targets
    /// a refinery specially — if the encoded index is not a structure it stores it raw (route reset); if it
    /// *is* a structure already linked (`variables[4] != 0`, i.e. busy) it does nothing. Otherwise it
    /// defers to the `Unit_SetDestination` primitive. Returns 0.
    public func setDestination(slot: Int, encoded: UInt16, in state: inout GameState) -> UInt16 {
        if encoded == 0 || !state.indexIsValid(encoded) {
            state.units[slot].targetMove = 0
            return 0
        }

        if UnitType(rawValue: Int(state.units[slot].o.type)) == .harvester {
            guard
                let sSlot = state.indexGetStructure(encoded)
            else {
                state.units[slot].targetMove = encoded
                state.units[slot].route[0] = 0xFF
                return 0
            }

            if state.structures[sSlot].o.script.variables[4] != 0 { return 0 }
        }

        unitSetDestination(slot: slot, encoded, in: &state)
        return 0
    }

    /// `Script_Unit_FindStructure` (`script/unit.c:1572`, native `0x25`): find an *idle, unlinked,
    /// unbusied* structure of the given `type` owned by the running unit's house (`Structure_Find` over the
    /// pool, gated `state == IDLE && linkedID == 0xFF && variables[4] == 0`). Returns its encoded index, or
    /// 0 if none. The GUARD/retreat scripts use it to locate a free repair facility/landing pad. Read-only.
    public func findStructure(slot: Int, type: UInt16, in state: GameState) -> UInt16 {
        var find = PoolFind(houseID: state.unitHouseID(state.units[slot]), type: type)
        while let sSlot = state.structureFind(&find) {
            let s = state.structures[sSlot]
            if s.state != .idle { continue }
            if s.o.linkedID != 0xFF { continue }
            if s.o.script.variables[4] != 0 { continue }
            return state.indexEncode(s.o.index, type: .structure)
        }
        return 0
    }

    /// `Script_Unit_IdleAction` (`script/unit.c:1760`, native `0x31`): the "sit idle" fidget a unit holding
    /// position (GUARD/AREA-GUARD) performs — twitch its sprite/orientation now and then. Ground units only
    /// (foot/tracked/wheeled); air/slither no-op. Draws `Tools_RandomLCG_Range(0, 10)` once: a foot unit
    /// rolling > 8 reseats its 6-bit sprite offset (`Tools_Random_256`); on a roll ≤ 2 it spins one
    /// orientation level to a random facing. The exact RNG draw order — LCG once, then up to three
    /// `Tools_Random_256` (the `&0x3F` reseat, then the level-select draw, then the orientation draw) — is
    /// faithful to OpenDUNE so the parity RNG stream stays aligned. Returns 0.
    public func idleAction(slot: Int, in state: inout GameState) -> UInt16 {
        let random = state.randomLCG.range(0, 10)
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }

        let movementType = UnitInfo[ut].movementType
        if movementType != .foot && movementType != .tracked && movementType != .wheeled { return 0 }

        if movementType == .foot && random > 8 {
            state.units[slot].spriteOffset = Int8(truncatingIfNeeded: state.random256.next() & 0x3F)
            state.unitUpdateMap(2, slot)
        }

        if random > 2 { return 0 }

        // Preserve the order of the two Tools_Random_256() draws: the level-select first, the new
        // orientation second.
        let level = (state.random256.next() & 1) == 0 ? 1 : 0
        let orientation = Int8(truncatingIfNeeded: state.random256.next())
        var u = state.units[slot]
        unitPrimitives.setOrientation(&u, orientation: orientation, rotateInstantly: false, level: level)
        state.units[slot] = u
        return 0
    }

    /// `Script_Unit_RemoveFog` (`script/unit.c`): lift the player's fog around the unit
    /// (`Unit_RemoveFog` → `Tile_RemoveFogInRadius` / `Map_UnveilTile`, the type's `fogUncoverRadius`).
    /// Returns 0. (Wired live once full combat parity landed — it was held off earlier because revealing an
    /// enemy shifts `FindBestTarget`'s visibility; the unit-vs-unit goldens confirm it now stays in step.)
    public func removeFog(slot: Int, in state: inout GameState) -> UInt16 {
        state.unitRemoveFog(slot)
        return 0
    }

    /// `Script_Unit_StartAnimation` (op 0x04, `script/unit.c:1475`): start the dying unit's **corpse**
    /// overlay animation at its tile — it lingers ~1200 ticks (two `PAUSE 600`s) before `STOP` clears it.
    /// Row 0/1 = on sand, 2/3 = on rock (`variables[1] == 1` adds 2); 3-frame infantry use `unitScript1`,
    /// other foot units `unitScript2`. The corpse rides the map's overlay tile (icon group 4). The
    /// animation is RNG-free to *start* (golden-safe); only `animationTick` (gated by `tickAnimations`)
    /// advances it. The next opcode (`Unit_Die`) removes the unit, so the corpse outlives the body.
    public func startAnimation(slot: Int, in state: inout GameState) -> UInt16 {
        let position = state.units[slot].o.position
        let packed = Int(position.packed)
        state.animationStopByTile(position.centered.packed)
        let houseID = state.unitHouseID(state.units[slot])
        state.map[packed].houseID = houseID

        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 1 }

        let lst = DefaultMapPrimitives().landscapeType(state.map[packed], tileIDs: state.tileIDs)
        var row = LandscapeInfo[lst].isSand ? 0 : 1
        if state.units[slot].o.script.variables[1] == 1 { row += 2 }
        let kind: AnimationKind = UnitInfo[ut].displayMode == .infantry3Frames ? .unitScript1 : .unitScript2
        state.animationStart(
            tableIndex: row,
            tile: position,
            tileLayout: 0,
            houseID: houseID,
            iconGroup: 4,
            kind: kind
        )
        return 1
    }

    /// `Script_General_FindIdle` (op 0x18, `script/general.c:400`): if `index` is an encoded structure of
    /// the unit's house, 1 when it's idle else 0; if `index` is a raw structure *type*, the encoded index
    /// of the first idle structure of that type for the house (0 if none); a unit/tile index → 0.
    public func findIdle(slot: Int, index: UInt16, in state: GameState) -> UInt16 {
        let houseID = state.units[slot].o.houseID
        switch Tools.indexType(index) {
            case .unit, .tile:
                return 0
            case .structure:
                guard let s = state.indexGetStructure(index) else { return 0 }

                if state.structures[s].o.houseID != houseID { return 0 }
                return state.structures[s].state == .idle ? 1 : 0
            case .none:
                var find = PoolFind(houseID: houseID, type: index)
                while let s = state.structureFind(&find) {
                    if state.structures[s].state != .idle { continue }
                    return state.indexEncode(state.structures[s].o.index, type: .structure)
                }
                return 0
        }
    }

    /// `Script_Unit_SetActionDefault` (op 0x0A, `script/unit.c:896`): switch the unit to its type's default
    /// player action (`actionsPlayer[3]`). Takes the action layer explicitly (this struct holds no runner).
    public func setActionDefault(
        slot: Int,
        scriptInfo: ScriptInfo,
        actions: UnitActions,
        engine: inout ScriptEngine,
        in state: inout GameState
    ) -> UInt16 {
        guard let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return 0 }

        actions.setAction(
            slot: slot,
            action: UInt8(UnitInfo[ut].o.actionsPlayer[3].rawValue),
            scriptInfo: scriptInfo,
            engine: &engine,
            in: &state
        )
        return 0
    }

    /// `Script_Unit_SetSprite` (op 0x13, `script/unit.c:404`): set the unit's render frame to a **negative**
    /// `spriteOffset` (`-(value & 0xFF)`) — the destroyed/death-animation frames index off `destroyedSpriteID`.
    public func setSprite(slot: Int, value: UInt16, in state: inout GameState) -> UInt16 {
        state.units[slot].spriteOffset = Int8(truncatingIfNeeded: -(Int(value & 0xFF)))
        return 0
    }

    /// `Script_Unit_Blink` (op 0x0B, `script/unit.c:1950`): flash the unit for 32 ticks (a render cue).
    public func blink(slot: Int, in state: inout GameState) -> UInt16 {
        state.units[slot].blinkCounter = 32
        return 0
    }

    /// `Script_Unit_GoToClosestStructure` (op 0x33, `script/unit.c:1798`): order the unit to the nearest
    /// idle, unlinked, un-busy structure of `type` owned by its house (a harvester → an empty refinery).
    /// Issues a Move to that structure; returns 1 if one was found, else 0. Takes the action layer
    /// explicitly (`UnitActions` + the live `engine`) since this struct holds no script runner.
    public func goToClosestStructure(
        slot: Int,
        type: UInt16,
        scriptInfo: ScriptInfo,
        actions: UnitActions,
        engine: inout ScriptEngine,
        in state: inout GameState
    ) -> UInt16 {
        let houseID = state.unitHouseID(state.units[slot])
        var best = -1
        var minDistance: UInt16 = 0
        var find = PoolFind(houseID: houseID, type: type)
        while let s = state.structureFind(&find) {
            if state.structures[s].state != .idle { continue }
            if state.structures[s].o.linkedID != 0xFF { continue }
            if state.structures[s].o.script.variables[4] != 0 { continue }
            let distance = Tile32.distanceRoundedUp(
                from: state.structures[s].o.position,
                to: state.units[slot].o.position
            )
            if distance >= minDistance && minDistance != 0 { continue }
            minDistance = distance
            best = s
        }
        if best == -1 { return 0 }

        actions.setAction(
            slot: slot,
            action: UInt8(ActionType.move.rawValue),
            scriptInfo: scriptInfo,
            engine: &engine,
            in: &state
        )
        unitSetDestination(slot: slot, state.indexEncode(state.structures[best].o.index, type: .structure), in: &state)
        return 1
    }

    /// `Script_Unit_Unknown2BD5` (op 0x37, `script/unit.c:1909`): validate the unit's `variables[4]` link —
    /// 1 if the linked unit/structure links back to this unit and shares its house; otherwise drop the
    /// (now-stale) link (and clear a linked unit's `targetMove`) and return 0.
    public func unknown2BD5(slot: Int, in state: inout GameState) -> UInt16 {
        let var4 = state.units[slot].o.script.variables[4]
        let selfEnc = state.indexEncode(state.units[slot].o.index, type: .unit)
        switch Tools.indexType(var4) {
            case .unit:
                if let u2 = state.indexGetUnit(var4) {
                    if selfEnc == state.units[u2].o.script.variables[4]
                            && state.units[u2].o.houseID == state.units[slot].o.houseID {
                        return 1
                    }
                    state.units[u2].targetMove = 0
                }
            case .structure:
                if let s = state.indexGetStructure(var4),
                        selfEnc == state.structures[s].o.script.variables[4]
                            && state.structures[s].o.houseID == state.units[slot].o.houseID {
                    return 1
                }
            default:
                break
        }
        state.objectScriptVariable4Clear(.unit(slot))
        return 0
    }

    /// `Script_Unit_Unknown2552` (`script/unit.c:1545`): if the unit is linked (via `variables[4]`) to a
    /// carryall, unlink it and clear that carryall's move target. Returns 0.
    public func unknown2552(slot: Int, in state: inout GameState) -> UInt16 {
        let link = state.units[slot].o.script.variables[4]
        if link == 0 { return 0 }
        guard
            let u2 = state.indexGetUnit(link),
            state.units[u2].o.type == UInt8(UnitType.carryall.rawValue)
        else { return 0 }

        state.objectScriptVariable4Clear(.unit(slot))
        state.units[u2].targetMove = 0
        return 0
    }
}
