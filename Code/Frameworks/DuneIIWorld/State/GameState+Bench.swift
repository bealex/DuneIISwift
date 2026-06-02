import DuneIIContracts

// Benchmark-only escape hatches. NOT part of the game model — they exist so `Apps/simbench` can stress the
// tick with far more units than the faithful pool (102 slots, partitioned into per-type `indexStart..indexEnd`
// ranges) allows, which is the only way to probe whether intra-tick parallelism pays off at scale (the
// faithful engine never reaches the ~128-entity threshold where it could). See
// `Documentation/Architecture/Parallelization.md`. These mutate the internal find-array/house-count that the
// faithful `unitAllocate` owns; gameplay must never call them.
public extension GameState {
    /// Force a fully-formed `unit` into `slot`, registering it in the find array + owning house's unit count,
    /// bypassing the faithful per-type allocator. The caller owns slot uniqueness/validity (use slots ≥ 102,
    /// the faithful range, with `DUNEII_UNIT_POOL` raised). The unit's `o.index` is rewritten to `slot`.
    mutating func benchInjectUnit(_ unit: Unit, at slot: Int) {
        var u = unit
        u.o.index = UInt16(slot)
        units[slot] = u
        unitFindArray.append(UInt16(slot))
        houses[Int(u.o.houseID)].unitCount &+= 1
    }

    /// Count of live units — `unitFindArray` is module-internal, so the benchmark reads it through here.
    var benchLiveUnitCount: Int { unitFindArray.count }

    /// Count of live structures (find-array length).
    var benchLiveStructureCount: Int { structureFindArray.count }
}
