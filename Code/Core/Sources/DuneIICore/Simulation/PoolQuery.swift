import Foundation

extension Simulation {
    /// Filter-and-resume cursor for pool iteration. Mirrors OpenDUNE's
    /// `PoolFindStruct`. See `Documentation/Architecture/Pools.md` §6.
    public struct PoolQuery: Sendable, Equatable {
        public var houseID: UInt8?
        public var type: UInt8?
        /// Opaque cursor. `-1` means "before the first call." Not intended
        /// for callers to read; kept `internal` to the package.
        internal var position: Int

        public init(houseID: UInt8? = nil, type: UInt8? = nil) {
            self.houseID = houseID
            self.type = type
            self.position = -1
        }
    }
}

// MARK: - UnitPool iteration

extension Simulation.UnitPool {
    /// Walk `findArray` in insertion order, skipping entries that fail
    /// `query.houseID` or `query.type` filters. Returns nil when exhausted.
    public func next(_ query: inout Simulation.PoolQuery) -> Simulation.UnitSlot? {
        // OpenDUNE's "continuing on an exhausted cursor" safety net.
        if query.position >= findArray.count && query.position != -1 { return nil }
        query.position += 1
        while query.position < findArray.count {
            let slot = slots[findArray[query.position]]
            if matches(slot, query: query) { return slot }
            query.position += 1
        }
        return nil
    }

    private func matches(_ slot: Simulation.UnitSlot, query: Simulation.PoolQuery) -> Bool {
        if let houseID = query.houseID, slot.houseID != houseID { return false }
        if let type = query.type, slot.type != type { return false }
        return true
    }
}

// MARK: - StructurePool iteration

extension Simulation.StructurePool {
    /// Walk `findArray` first, then yield the three reserved aggregate
    /// slots (`indexWall`, `indexSlab2x2`, `indexSlab1x1`) in that order,
    /// but only if the reserved slot's `isUsed` flag is set. Mirrors
    /// OpenDUNE's `Structure_Find` tail-trio walk.
    public func next(_ query: inout Simulation.PoolQuery) -> Simulation.StructureSlot? {
        let walkLength = findArray.count + 3
        if query.position >= walkLength && query.position != -1 { return nil }
        query.position += 1

        while query.position < walkLength {
            let slot: Simulation.StructureSlot?
            if query.position < findArray.count {
                slot = slots[findArray[query.position]]
            } else {
                let reservedIndex: Int
                switch query.position - findArray.count {
                case 0:  reservedIndex = Self.indexWall
                case 1:  reservedIndex = Self.indexSlab2x2
                case 2:  reservedIndex = Self.indexSlab1x1
                default: return nil
                }
                let reserved = slots[reservedIndex]
                slot = reserved.isUsed ? reserved : nil
            }
            if let s = slot, matches(s, query: query) { return s }
            query.position += 1
        }
        return nil
    }

    private func matches(_ slot: Simulation.StructureSlot, query: Simulation.PoolQuery) -> Bool {
        if let houseID = query.houseID, slot.houseID != houseID { return false }
        if let type = query.type, slot.type != type { return false }
        return true
    }
}
