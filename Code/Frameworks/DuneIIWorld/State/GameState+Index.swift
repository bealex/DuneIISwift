import DuneIIContracts

/// A resolved reference to an `Object`-bearing pool slot, returned by `indexGetObject`. (Swift can't
/// hand back a pointer into the pool array the way OpenDUNE's `Tools_Index_GetObject` returns
/// `Object*`, so callers read/mutate via the pool + index.)
public enum ObjectRef: Sendable, Equatable {
    case unit(Int)
    case structure(Int)
}

/// The pool-dependent `Tools_Index_*` functions (`src/tools.c`), deferred from the pure `Tools`
/// helpers until the pools existed. They live on `GameState` because they read the object pools.
public extension GameState {
    /// `Tools_Index_Encode`.
    func indexEncode(_ index: UInt16, type: IndexType) -> UInt16 {
        switch type {
            case .tile:
                let x = UInt16(Tile32.packedX(index))
                let y = UInt16(Tile32.packedY(index))
                var ret = (x << 1) + 1
                ret |= ((y << 1) + 1) << 7
                return ret | 0xC000
            case .unit:
                if index >= UInt16(Pool.unitIndexMax)
                    || !units[Int(index)].o.flags.contains(.allocated) { return 0 }
                return index | 0x4000
            case .structure:
                return index | 0x8000
            case .none:
                return 0
        }
    }

    /// `Tools_Index_IsValid`.
    func indexIsValid(_ encoded: UInt16) -> Bool {
        if encoded == 0 { return false }
        let index = Tools.indexDecode(encoded)
        switch Tools.indexType(encoded) {
            case .unit:
                if index >= UInt16(Pool.unitIndexMax) { return false }
                let f = units[Int(index)].o.flags
                return f.contains(.used) && f.contains(.allocated)
            case .structure:
                if index >= UInt16(Pool.structureIndexMaxHard) { return false }
                return structures[Int(index)].o.flags.contains(.used)
            case .tile:
                return true
            case .none:
                return false
        }
    }

    /// `Tools_Index_GetUnit`: the unit slot index, or `nil`.
    func indexGetUnit(_ encoded: UInt16) -> Int? {
        guard Tools.indexType(encoded) == .unit else { return nil }
        let index = Tools.indexDecode(encoded)
        return index < UInt16(Pool.unitIndexMax) ? Int(index) : nil
    }

    /// `Tools_Index_GetStructure`: the structure slot index, or `nil`.
    func indexGetStructure(_ encoded: UInt16) -> Int? {
        guard Tools.indexType(encoded) == .structure else { return nil }
        let index = Tools.indexDecode(encoded)
        return index < UInt16(Pool.structureIndexMaxHard) ? Int(index) : nil
    }

    /// `Tools_Index_GetObject`: which pool + slot the encoded index resolves to, or `nil`.
    func indexGetObject(_ encoded: UInt16) -> ObjectRef? {
        switch Tools.indexType(encoded) {
            case .unit:
                let i = Tools.indexDecode(encoded)
                return i < UInt16(Pool.unitIndexMax) ? .unit(Int(i)) : nil
            case .structure:
                let i = Tools.indexDecode(encoded)
                return i < UInt16(Pool.structureIndexMaxHard) ? .structure(Int(i)) : nil
            default:
                return nil
        }
    }

    /// The `Object` referenced by an `ObjectRef`.
    func object(_ ref: ObjectRef) -> Object {
        switch ref {
            case .unit(let i): return units[i].o
            case .structure(let i): return structures[i].o
        }
    }

    /// `Tools_Index_GetTile`: the map position an encoded index points at (tile, unit position, or a
    /// structure's centre — its position plus the layout tile diff).
    func indexGetTile(_ encoded: UInt16) -> Tile32 {
        let index = Tools.indexDecode(encoded)
        switch Tools.indexType(encoded) {
            case .tile:
                return Tile32.unpack(index)
            case .unit:
                return index < UInt16(Pool.unitIndexMax) ? units[Int(index)].o.position : Tile32(x: 0, y: 0)
            case .structure:
                if index >= UInt16(Pool.structureIndexMaxHard) { return Tile32(x: 0, y: 0) }
                let s = structures[Int(index)]
                guard let st = StructureType(rawValue: Int(s.o.type)) else { return Tile32(x: 0, y: 0) }
                let diff = StructureLayoutInfo[StructureInfo[st].layout].tileDiff
                return Tile32.addDiff(s.o.position, diff)
            case .none:
                return Tile32(x: 0, y: 0)
        }
    }
}
