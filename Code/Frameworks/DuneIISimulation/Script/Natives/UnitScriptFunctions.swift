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
            default:   return 0
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
        if u.orientation[index].speed != 0 { return 1 }                 // already rotating
        if !state.indexIsValid(u.targetAttack) { return 0 }

        let orientation = Tile32.direction(from: u.o.position, to: state.indexGetTile(u.targetAttack))
        if orientation == u.orientation[index].current { return 0 }     // already aimed
        unitPrimitives.setOrientation(&state.units[slot], orientation: orientation, rotateInstantly: false, level: index)
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
        let tile = Tile32.moveByRandom(state.units[slot].o.position, distance: 80, center: true,
                                       rng: &state.random256)
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
            unitPrimitives.setOrientation(&state.units[slot], orientation: orientation, rotateInstantly: false, level: 0)
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
}
