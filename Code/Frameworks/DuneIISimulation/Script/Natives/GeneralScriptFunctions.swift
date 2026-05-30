import DuneIIContracts
import DuneIIWorld

/// The category-independent EMC native script functions (`Script_General_*`, `src/script/general.c`),
/// callable from unit / structure / team scripts (op 14).
///
/// Per project convention these are **clean functions with explicit, named parameters** — the
/// OpenDUNE originals read their arguments off the `ScriptEngine` stack with `STACK_PEEK`, but here a
/// thin VM-glue layer extracts those and passes them in, so the logic stays legible and each function
/// is independently, exhaustively testable against the oracle. Stack handling lives only in the glue.
public struct GeneralScriptFunctions: Sendable {
    public init() {}

    /// `Script_General_NoOperation`: does nothing, returns 0.
    public func noOperation() -> UInt16 { 0 }

    /// `Script_General_Delay`: the suspend duration (in ticks) for a requested `ticks` delay. The glue
    /// stores the result in `engine.delay`.
    public func delay(ticks: UInt16) -> UInt16 { ticks / 5 }

    /// `Script_General_DelayRandom`: a random suspend duration up to `maxTicks`. Draws one `Random256`
    /// byte (mutating the RNG). The glue stores the result in `engine.delay`.
    public func delayRandom(maxTicks: UInt16, in state: inout GameState) -> UInt16 {
        let r = UInt32(state.random256.next()) * UInt32(maxTicks) / 256
        return UInt16(r) / 5
    }

    /// `Script_General_RandomRange`: a `RandomLCG` value in `[min, max]` (mutates the RNG).
    public func randomRange(min: UInt16, max: UInt16, in state: inout GameState) -> UInt16 {
        state.randomLCG.range(min, max)
    }

    /// `Script_General_GetDistanceToTile`: tile distance from `from` to the tile `encoded` points at,
    /// or `0xFFFF` if `encoded` is not a valid index.
    public func getDistanceToTile(from: Tile32, encoded: UInt16, in state: GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return 0xFFFF }
        return Tile32.distance(from: from, to: state.indexGetTile(encoded))
    }

    /// `Script_General_GetDistanceToObject` (`script/general.c:162`, native `0x3E`) → `Object_GetDistance`
    /// `ToEncoded` (`object.c:114`): tile distance from `from` (the running object's position) to the
    /// unit/structure/tile `encoded` points at; `0xFFFF` if `encoded` is invalid. A *structure* target is
    /// measured to the edge tile facing `from` (the `layoutEdgeTiles` offset rotated by the 8-dir from
    /// `from`, `+4` to the near side), not its origin; a unit/tile target is measured to its tile.
    public func getDistanceToObject(from: Tile32, encoded: UInt16, in state: GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return 0xFFFF }

        let position: Tile32
        if let sSlot = state.indexGetStructure(encoded), let st = StructureType(rawValue: Int(state.structures[sSlot].o.type)) {
            let s = state.structures[sSlot]
            let dir8 = Orientation.to8(UInt8(bitPattern: Tile32.direction(from: from, to: s.o.position)))
            // OpenDUNE indexes the *structure's* layout here — an un-gated enhancement over 1.07's
            // unit-type index; we match the oracle (the golden source). Only affects a structure target.
            let edge = StructureLayoutInfo[StructureInfo[st].layout].edgeTiles[Int((dir8 &+ 4) & 7)]
            position = Tile32.unpack(s.o.position.packed &+ edge)
        } else {
            position = state.indexGetTile(encoded)
        }

        return Tile32.distance(from: from, to: position)
    }

    /// `Script_General_IsEnemy`: 1 iff `encoded` is a valid unit/structure of a different house than
    /// `currentHouseID` (the running object's house); 0 otherwise. The glue resolves `currentHouseID`
    /// (a unit's is deviation-aware, `Unit_GetHouseID`; otherwise the object's `houseID`).
    public func isEnemy(currentHouseID: UInt8, encoded: UInt16, in state: GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return 0 }
        switch Tools.indexType(encoded) {
            case .unit:
                guard let slot = state.indexGetUnit(encoded) else { return 0 }
                return state.unitHouseID(state.units[slot]) != currentHouseID ? 1 : 0
            case .structure:
                guard let slot = state.indexGetStructure(encoded) else { return 0 }
                return state.structures[slot].o.houseID != currentHouseID ? 1 : 0
            default:
                return 0
        }
    }

    /// `Script_General_IsFriendly`: 1 for a valid, on-map, allied object; `0xFFFF` for an enemy; 0 when
    /// the index resolves to no usable object.
    public func isFriendly(currentHouseID: UInt8, encoded: UInt16, in state: GameState) -> UInt16 {
        guard let ref = state.indexGetObject(encoded) else { return 0 }
        let o = state.object(ref)
        if o.flags.contains(.isNotOnMap) || !o.flags.contains(.used) { return 0 }
        return isEnemy(currentHouseID: currentHouseID, encoded: encoded, in: state) == 0 ? 1 : 0xFFFF
    }

    /// `Script_General_GetIndexType`: the `IT_*` type of `encoded`, or `0xFFFF` if invalid.
    public func getIndexType(encoded: UInt16, in state: GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return 0xFFFF }
        return UInt16(Tools.indexType(encoded).rawValue)
    }

    /// `Script_General_DecodeIndex`: the bare index of `encoded`, or `0xFFFF` if invalid.
    public func decodeIndex(encoded: UInt16, in state: GameState) -> UInt16 {
        if !state.indexIsValid(encoded) { return 0xFFFF }
        return Tools.indexDecode(encoded)
    }

    /// `Script_General_GetOrientation`: the base orientation (`orientation[0].current`) of the unit
    /// `encoded` points at, or 128 if it is not a unit.
    public func getOrientation(encoded: UInt16, in state: GameState) -> UInt16 {
        guard let slot = state.indexGetUnit(encoded) else { return 128 }
        return UInt16(bitPattern: Int16(state.units[slot].orientation[0].current))
    }

    /// `Script_General_GetLinkedUnitType`: the unit type linked to the running object (`linkedID`), or
    /// `0xFFFF` if nothing is linked.
    public func getLinkedUnitType(linkedID: UInt8, in state: GameState) -> UInt16 {
        if linkedID == 0xFF { return 0xFFFF }
        return UInt16(state.units[Int(linkedID)].o.type)
    }

    /// `Script_General_UnitCount`: how many on-map units of `type` (`0xFFFF` = any) belong to the
    /// running object's house.
    public func unitCount(houseID: UInt8, type: UInt16, in state: GameState) -> UInt16 {
        var find = PoolFind(houseID: houseID, type: type)
        var count: UInt16 = 0
        while state.unitFind(&find) != nil { count &+= 1 }
        return count
    }
}
