import DuneIIContracts

/// Object-pool operations: `find` iterators, `allocate`, and recount. Faithful ports of OpenDUNE's
/// `src/pool/*.c`. `find` returns the slot index (into the corresponding pool array) or `nil`, and
/// advances the cursor in the `inout PoolFind`. `allocate` returns the new slot index or `nil`.
public extension GameState {
    /// `Unit_GetHouseID` (`unit.c`): a deviated unit belongs to Ordos in 1.07 (non-enhanced).
    func unitHouseID(_ u: Unit) -> UInt8 {
        u.deviated != 0 ? UInt8(HouseID.ordos.rawValue) : u.o.houseID
    }

    // MARK: - Find

    /// `Unit_Find`.
    func unitFind(_ find: inout PoolFind) -> Int? {
        let count = UInt16(unitFindArray.count)
        if find.index >= count && find.index != 0xFFFF { return nil }
        find.index = find.index &+ 1
        while find.index < count {
            let slot = unitFindArray[Int(find.index)]
            let u = units[Int(slot)]
            let skip = u.o.flags.contains(.isNotOnMap) && validateStrictIfZero == 0
            if !skip
                && (find.houseID == Pool.houseInvalid || find.houseID == unitHouseID(u))
                && (find.type == 0xFFFF || find.type == UInt16(u.o.type)) {
                return Int(slot)
            }
            find.index = find.index &+ 1
        }
        return nil
    }

    /// `Structure_Find`. Iterates the find array plus the 3 special slots (wall, 2×2 slab, 1×1 slab)
    /// that are never kept in the find array.
    func structureFind(_ find: inout PoolFind) -> Int? {
        let count = UInt16(structureFindArray.count)
        if find.index >= count &+ 3 && find.index != 0xFFFF { return nil }
        find.index = find.index &+ 1
        while find.index < count &+ 3 {
            var slot: Int? = nil
            if find.index < count {
                slot = Int(structureFindArray[Int(find.index)])
            } else {
                let special: UInt16
                switch find.index - count {
                    case 0: special = Pool.structureIndexWall
                    case 1: special = Pool.structureIndexSlab2x2
                    default: special = Pool.structureIndexSlab1x1
                }
                if structures[Int(special)].o.index == special { slot = Int(special) }
            }
            if let idx = slot {
                let s = structures[idx]
                let skip = s.o.flags.contains(.isNotOnMap) && validateStrictIfZero == 0
                if !skip
                    && (find.houseID == Pool.houseInvalid || find.houseID == s.o.houseID)
                    && (find.type == 0xFFFF || find.type == UInt16(s.o.type)) {
                    return idx
                }
            }
            find.index = find.index &+ 1
        }
        return nil
    }

    /// `House_Find` — every entry in the house find array is valid.
    func houseFind(_ find: inout PoolFind) -> Int? {
        let count = UInt16(houseFindArray.count)
        if find.index >= count && find.index != 0xFFFF { return nil }
        find.index = find.index &+ 1
        if find.index < count { return Int(houseFindArray[Int(find.index)]) }
        return nil
    }

    /// `Team_Find`.
    func teamFind(_ find: inout PoolFind) -> Int? {
        let count = UInt16(teamFindArray.count)
        if find.index >= count && find.index != 0xFFFF { return nil }
        find.index = find.index &+ 1
        while find.index < count {
            let slot = teamFindArray[Int(find.index)]
            if find.houseID == Pool.houseInvalid || find.houseID == teams[Int(slot)].houseID {
                return Int(slot)
            }
            find.index = find.index &+ 1
        }
        return nil
    }

    // MARK: - Map / type queries

    /// `Unit_Get_ByPackedTile` (`unit.c`): the slot index of the unit occupying `packed`, or `nil` if
    /// the tile is off-map or carries no unit. (`g_map[packed].index` is 1-based: 1 means unit slot 0.)
    func unitGetByPackedTile(_ packed: UInt16) -> Int? {
        if Tile32.isOutOfMap(packed) { return nil }
        let tile = map[Int(packed)]
        if !tile.hasUnit { return nil }
        return Int(tile.index) - 1
    }

    /// `Unit_IsTypeOnMap` (`unit.c:474`): is any on-map unit matching `houseID` (or any, when
    /// `Pool.houseInvalid`) and `typeID` (or any, when `UNIT_INVALID` = `0xFF`) present? Units flagged
    /// `isNotOnMap` are skipped unless strict-validation is active.
    func unitIsTypeOnMap(houseID: UInt8, typeID: UInt8) -> Bool {
        for slot in unitFindArray {
            let u = units[Int(slot)]
            if houseID != Pool.houseInvalid && unitHouseID(u) != houseID { continue }
            if typeID != 0xFF && u.o.type != typeID { continue }
            if validateStrictIfZero == 0 && u.o.flags.contains(.isNotOnMap) { continue }
            return true
        }
        return false
    }

    // MARK: - Allocate

    /// `Unit_Allocate`. Picks a free slot inside the type's `[indexStart, indexEnd]` band when
    /// `index` is 0/invalid. Returns the slot index, or `nil` if none free / the house is at its cap.
    mutating func unitAllocate(index: UInt16, type: UInt8, houseID: UInt8) -> Int? {
        if type == 0xFF || houseID == 0xFF { return nil }
        guard let unitType = UnitType(rawValue: Int(type)) else { return nil }

        let h = houses[Int(houseID)]
        if h.unitCount >= h.unitCountMax {
            let mt = UnitInfo[unitType].movementType
            if mt != .winger && mt != .slither && validateStrictIfZero == 0 { return nil }
        }

        var idx: Int
        if index == 0 || index == Pool.unitIndexInvalid {
            let info = UnitInfo[unitType]
            idx = Int(info.indexStart)
            let end = Int(info.indexEnd)
            while idx <= end {
                if !units[idx].o.flags.contains(.used) { break }
                idx += 1
            }
            if idx > end { return nil }
        } else {
            idx = Int(index)
            if units[idx].o.flags.contains(.used) { return nil }
        }

        houses[Int(houseID)].unitCount += 1

        var u = Unit()
        u.o.index = UInt16(idx)
        u.o.type = type
        u.o.houseID = houseID
        u.o.linkedID = 0xFF
        u.o.flags = [.used, .allocated, .isUnit]
        u.route[0] = 0xFF
        if unitType == .sandworm { u.amount = 3 }
        units[idx] = u

        unitFindArray.append(UInt16(idx))
        return idx
    }

    /// `Structure_Allocate`. Slab/wall types route to their fixed special slots (and are not added to
    /// the find array); all others take the first free soft slot (or the given `index`).
    mutating func structureAllocate(index: UInt16, type: UInt8) -> Int? {
        var idx: Int
        var special = true
        switch Int(type) {
            case StructureType.slab1x1.rawValue: idx = Int(Pool.structureIndexSlab1x1)
            case StructureType.slab2x2.rawValue: idx = Int(Pool.structureIndexSlab2x2)
            case StructureType.wall.rawValue:    idx = Int(Pool.structureIndexWall)
            default:
                special = false
                if index == Pool.structureIndexInvalid {
                    idx = 0
                    while idx < Pool.structureIndexMaxSoft {
                        if !structures[idx].o.flags.contains(.used) { break }
                        idx += 1
                    }
                    if idx == Pool.structureIndexMaxSoft { return nil }
                } else {
                    idx = Int(index)
                    if structures[idx].o.flags.contains(.used) { return nil }
                }
        }

        var s = Structure()
        s.o.index = UInt16(idx)
        s.o.type = type
        s.o.linkedID = 0xFF
        s.o.flags = [.used, .allocated]
        structures[idx] = s

        if !special { structureFindArray.append(UInt16(idx)) }
        return idx
    }

    /// `House_Allocate`. `index` is the `HouseID`.
    mutating func houseAllocate(index: UInt8) -> Int? {
        if Int(index) >= Pool.houseIndexMax { return nil }
        if houses[Int(index)].flags.contains(.used) { return nil }

        var h = House()
        h.index = index
        h.flags = [.used]
        h.starportLinkedID = Pool.unitIndexInvalid
        houses[Int(index)] = h

        houseFindArray.append(UInt16(index))
        return Int(index)
    }

    /// `Team_Allocate`.
    mutating func teamAllocate(index: UInt16) -> Int? {
        var idx: Int
        if index == Pool.teamIndexInvalid {
            idx = 0
            while idx < Pool.teamIndexMax {
                if !teams[idx].flags.contains(.used) { break }
                idx += 1
            }
            if idx == Pool.teamIndexMax { return nil }
        } else {
            idx = Int(index)
            if teams[idx].flags.contains(.used) { return nil }
        }

        var t = Team()
        t.index = UInt16(idx)
        t.flags = [.used]
        teams[idx] = t

        teamFindArray.append(UInt16(idx))
        return idx
    }

    // MARK: - Recount

    /// `Unit_Recount`: rebuild the unit find array + per-house unit counts from the slot array.
    mutating func unitRecount() {
        for i in houseFindArray { houses[Int(i)].unitCount = 0 }
        unitFindArray.removeAll(keepingCapacity: true)
        for index in 0..<Pool.unitIndexMax where units[index].o.flags.contains(.used) {
            houses[Int(units[index].o.houseID)].unitCount += 1
            unitFindArray.append(UInt16(index))
        }
    }
}
