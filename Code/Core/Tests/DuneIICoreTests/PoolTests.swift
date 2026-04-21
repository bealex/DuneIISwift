import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.Simulation.Pools")
struct PoolTests {
    // MARK: - Empty initialisation

    @Test("empty UnitPool has 102 zeroed slots and empty findArray")
    func unitPoolEmpty() {
        let pool = Simulation.UnitPool()
        #expect(pool.slots.count == 102)
        #expect(pool.slots.allSatisfy { !$0.isUsed && !$0.isAllocated && $0.index == 0 })
        #expect(pool.findArray.isEmpty)
    }

    @Test("empty StructurePool has 82 zeroed slots and empty findArray")
    func structurePoolEmpty() {
        let pool = Simulation.StructurePool()
        #expect(pool.slots.count == 82)
        #expect(pool.findArray.isEmpty)
    }

    @Test("empty HousePool has 6 zeroed slots and empty findArray")
    func housePoolEmpty() {
        let pool = Simulation.HousePool()
        #expect(pool.slots.count == 6)
        #expect(pool.findArray.isEmpty)
    }

    // MARK: - UnitPool

    @Test("UnitPool.allocate(at:) populates slot and findArray")
    func unitAllocateAt() {
        var pool = Simulation.UnitPool()
        let result = pool.allocate(at: 5, type: 3, houseID: 1)
        #expect(result == 5)
        #expect(pool.slots[5].isUsed)
        #expect(pool.slots[5].isAllocated)
        #expect(pool.slots[5].index == 5)
        #expect(pool.slots[5].type == 3)
        #expect(pool.slots[5].houseID == 1)
        #expect(pool.slots[5].linkedID == 0xFF)
        #expect(pool.findArray == [5])
    }

    @Test("UnitPool.allocate(at:) on a used slot returns nil and leaves state alone")
    func unitAllocateAtTwice() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 5, type: 3, houseID: 1)
        let snapshot = pool
        let second = pool.allocate(at: 5, type: 4, houseID: 2)
        #expect(second == nil)
        #expect(pool == snapshot)
    }

    @Test("UnitPool.allocate(in:) returns the first unused index in the range")
    func unitAllocateInRange() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 0, type: 1, houseID: 1)
        let result = pool.allocate(in: 0...3, type: 2, houseID: 1)
        #expect(result == 1)
        #expect(pool.findArray == [0, 1])
    }

    @Test("UnitPool.allocate(in:) returns nil when range is fully used")
    func unitAllocateInFullRange() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 0, type: 1, houseID: 1)
        _ = pool.allocate(at: 1, type: 1, houseID: 1)
        _ = pool.allocate(at: 2, type: 1, houseID: 1)
        let result = pool.allocate(in: 0...2, type: 2, houseID: 1)
        #expect(result == nil)
    }

    @Test("UnitPool.free preserves find-array insertion order")
    func unitFreePreservesOrder() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 2, type: 1, houseID: 1)
        _ = pool.allocate(at: 5, type: 1, houseID: 1)
        _ = pool.allocate(at: 8, type: 1, houseID: 1)
        #expect(pool.findArray == [2, 5, 8])
        pool.free(at: 5)
        #expect(pool.findArray == [2, 8])
        #expect(pool.slots[5].isUsed == false)
    }

    @Test("UnitPool.free of an unused slot is a no-op")
    func unitFreeUnusedNoop() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 2, type: 1, houseID: 1)
        let snapshot = pool
        pool.free(at: 7)             // not allocated
        #expect(pool == snapshot)
    }

    // MARK: - StructurePool

    @Test("StructurePool.allocateReserved at WALL slot always succeeds")
    func structureAllocateReservedRepeated() {
        var pool = Simulation.StructurePool()
        let first = pool.allocateReserved(at: Simulation.StructurePool.indexWall, type: 9)
        #expect(first == Simulation.StructurePool.indexWall)
        #expect(pool.slots[Simulation.StructurePool.indexWall].isUsed)
        #expect(pool.findArray.isEmpty)             // reserved slots stay out of the cache

        let second = pool.allocateReserved(at: Simulation.StructurePool.indexWall, type: 9)
        #expect(second == Simulation.StructurePool.indexWall)
        #expect(pool.findArray.isEmpty)
    }

    @Test("StructurePool.allocate(in:) skips the reserved tail (79/80/81)")
    func structureAllocateSkipsReserved() {
        var pool = Simulation.StructurePool()
        // Fill indices 0..78 with normal allocations.
        for i in 0..<Simulation.StructurePool.capacitySoft {
            #expect(pool.allocate(at: i, type: 1, houseID: 1) == i)
        }
        // The next normal-range allocation must fail because 79/80/81 are reserved.
        let result = pool.allocate(in: 0...(Simulation.StructurePool.capacityHard - 1), type: 1, houseID: 1)
        #expect(result == nil)
    }

    @Test("StructurePool.free of a reserved slot does not touch findArray")
    func structureFreeReservedNoFindArrayChange() {
        var pool = Simulation.StructurePool()
        _ = pool.allocateReserved(at: Simulation.StructurePool.indexSlab2x2, type: 8)
        _ = pool.allocate(at: 0, type: 1, houseID: 1)
        let snapshot = pool.findArray
        pool.free(at: Simulation.StructurePool.indexSlab2x2)
        #expect(pool.findArray == snapshot)         // unchanged: reserved slots aren't in it
    }

    // MARK: - HousePool

    @Test("HousePool.allocate(at:) twice on same index returns nil")
    func houseAllocateTwiceFails() {
        var pool = Simulation.HousePool()
        let first = pool.allocate(at: 3)
        #expect(first == 3)
        let second = pool.allocate(at: 3)
        #expect(second == nil)
    }

    @Test("HousePool.allocate(at:) out of range returns nil")
    func houseAllocateOutOfRange() {
        var pool = Simulation.HousePool()
        #expect(pool.allocate(at: -1) == nil)
        #expect(pool.allocate(at: 6) == nil)
        #expect(pool.findArray.isEmpty)
    }

    @Test("HousePool.free leaves slots[i].isUsed == true (the OpenDUNE quirk)")
    func houseFreeLeavesUsed() {
        var pool = Simulation.HousePool()
        _ = pool.allocate(at: 2)
        pool.free(at: 2)
        #expect(pool.findArray.isEmpty)
        #expect(pool.slots[2].isUsed == true)        // documented OpenDUNE behaviour
        // Re-allocation of the same slot therefore fails, mirroring OpenDUNE.
        #expect(pool.allocate(at: 2) == nil)
    }

    // MARK: - Filtered iteration (`PoolQuery`)

    @Test("UnitPool.next yields all slots in insertion order when no filter is set")
    func unitFindAny() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 7, type: 2, houseID: 1)
        _ = pool.allocate(at: 3, type: 4, houseID: 2)
        _ = pool.allocate(at: 15, type: 2, houseID: 1)

        var query = Simulation.PoolQuery()
        var seen: [Int] = []
        while let slot = pool.next(&query) { seen.append(Int(slot.index)) }
        #expect(seen == [7, 3, 15])
    }

    @Test("UnitPool.next applies the houseID filter")
    func unitFindByHouse() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 7, type: 2, houseID: 1)
        _ = pool.allocate(at: 3, type: 4, houseID: 2)
        _ = pool.allocate(at: 15, type: 2, houseID: 1)

        var query = Simulation.PoolQuery(houseID: 1)
        var seen: [Int] = []
        while let slot = pool.next(&query) { seen.append(Int(slot.index)) }
        #expect(seen == [7, 15])
    }

    @Test("UnitPool.next applies both houseID and type filters")
    func unitFindByHouseAndType() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 7, type: 2, houseID: 1)
        _ = pool.allocate(at: 8, type: 3, houseID: 1)        // type mismatch
        _ = pool.allocate(at: 3, type: 4, houseID: 2)
        _ = pool.allocate(at: 15, type: 2, houseID: 1)

        var query = Simulation.PoolQuery(houseID: 1, type: 2)
        var seen: [Int] = []
        while let slot = pool.next(&query) { seen.append(Int(slot.index)) }
        #expect(seen == [7, 15])
    }

    @Test("UnitPool.next continues to return nil on an exhausted query")
    func unitFindExhaustedIdempotent() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 2, type: 1, houseID: 1)
        var query = Simulation.PoolQuery()
        _ = pool.next(&query)                                  // returns slot 2
        #expect(pool.next(&query) == nil)
        #expect(pool.next(&query) == nil)                      // still nil, no crash
    }

    @Test("UnitPool.next after free skips the freed slot")
    func unitFindAfterFree() {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 7, type: 2, houseID: 1)
        _ = pool.allocate(at: 3, type: 2, houseID: 1)
        _ = pool.allocate(at: 15, type: 2, houseID: 1)
        pool.free(at: 3)

        var query = Simulation.PoolQuery()
        var seen: [Int] = []
        while let slot = pool.next(&query) { seen.append(Int(slot.index)) }
        #expect(seen == [7, 15])
    }

    @Test("StructurePool.next walks findArray then the three reserved slots (if allocated)")
    func structureFindWalksReservedTail() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 0, type: 1, houseID: 1)
        _ = pool.allocate(at: 5, type: 2, houseID: 1)
        _ = pool.allocateReserved(at: Simulation.StructurePool.indexWall, type: 9)
        _ = pool.allocateReserved(at: Simulation.StructurePool.indexSlab1x1, type: 8)
        // indexSlab2x2 deliberately left unallocated.

        var query = Simulation.PoolQuery()
        var seen: [Int] = []
        while let slot = pool.next(&query) { seen.append(Int(slot.index)) }
        #expect(seen == [0, 5, Simulation.StructurePool.indexWall, Simulation.StructurePool.indexSlab1x1])
    }

    @Test("StructurePool.next filter applies to reserved slots")
    func structureFindFiltersReservedSlots() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 0, type: 1, houseID: 1)
        _ = pool.allocateReserved(at: Simulation.StructurePool.indexWall, type: 9)

        // type 1 filter should visit the normal slot only — the reserved
        // WALL aggregate has type 9.
        var query = Simulation.PoolQuery(type: 1)
        var seen: [Int] = []
        while let slot = pool.next(&query) { seen.append(Int(slot.index)) }
        #expect(seen == [0])
    }

    // MARK: - Determinism

    @Test("identical allocation sequences yield Equatable-equal pools")
    func deterministicEquality() {
        func build() -> Simulation.UnitPool {
            var p = Simulation.UnitPool()
            _ = p.allocate(at: 7, type: 2, houseID: 1)
            _ = p.allocate(at: 13, type: 4, houseID: 2)
            _ = p.allocate(at: 99, type: 5, houseID: 0)
            return p
        }
        #expect(build() == build())
    }
}
