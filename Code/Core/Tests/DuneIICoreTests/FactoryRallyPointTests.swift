import Foundation
import Testing
@testable import DuneIICore

@Suite("Factory rally point — StructureSlot field + setRallyPoint + completeConstruction hook")
struct FactoryRallyPointTests {

    private let BARRACKS: UInt8 = 10
    private let LIGHT_VEHICLE: UInt8 = 3
    private let CYARD: UInt8 = 8
    private let WINDTRAP: UInt8 = 9
    private let SOLDIER: UInt8 = 4
    private let TRIKE: UInt8 = 13

    private func readyFactory(
        type: UInt8, at anchorTile: (x: Int, y: Int), pool: inout Simulation.StructurePool,
        produces: UInt8
    ) -> Int {
        let idx = pool.allocate(
            in: 0...Simulation.StructurePool.capacitySoft - 1,
            type: type, houseID: Simulation.House.atreides
        )!
        var slot = pool[idx]
        slot.positionX = UInt16(anchorTile.x * 256)
        slot.positionY = UInt16(anchorTile.y * 256)
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(produces)
        pool[idx] = slot
        return idx
    }

    // MARK: Slot default

    @Test("StructureSlot.rallyPointPacked defaults to 0xFFFF sentinel")
    func defaultIsSentinel() {
        let slot = Simulation.StructureSlot()
        #expect(slot.rallyPointPacked == 0xFFFF)
    }

    @Test("Pool.allocate leaves rallyPointPacked at sentinel")
    func allocateKeepsSentinel() {
        var pool = Simulation.StructurePool()
        let idx = pool.allocate(at: 5, type: BARRACKS, houseID: Simulation.House.atreides)!
        #expect(pool[idx].rallyPointPacked == 0xFFFF)
    }

    // MARK: setRallyPoint

    @Test("setRallyPoint on a BARRACKS stamps packed tile")
    func setOnFactoryStamps() {
        var pool = Simulation.StructurePool()
        let idx = pool.allocate(at: 5, type: BARRACKS, houseID: Simulation.House.atreides)!
        #expect(Simulation.Structures.setRallyPoint(yardIndex: idx, tile: (x: 10, y: 20), pool: &pool))
        #expect(pool[idx].rallyPointPacked == UInt16(20 * 64 + 10))
    }

    @Test("setRallyPoint nil clears to sentinel")
    func clearReturnsSentinel() {
        var pool = Simulation.StructurePool()
        let idx = pool.allocate(at: 5, type: LIGHT_VEHICLE, houseID: Simulation.House.atreides)!
        _ = Simulation.Structures.setRallyPoint(yardIndex: idx, tile: (x: 1, y: 2), pool: &pool)
        #expect(pool[idx].rallyPointPacked != 0xFFFF)
        #expect(Simulation.Structures.setRallyPoint(yardIndex: idx, tile: nil, pool: &pool))
        #expect(pool[idx].rallyPointPacked == 0xFFFF)
    }

    @Test("setRallyPoint rejects non-factory yard (CYARD)")
    func rejectsNonFactory() {
        var pool = Simulation.StructurePool()
        let idx = pool.allocate(at: 5, type: CYARD, houseID: Simulation.House.atreides)!
        #expect(!Simulation.Structures.setRallyPoint(yardIndex: idx, tile: (x: 5, y: 5), pool: &pool))
        #expect(pool[idx].rallyPointPacked == 0xFFFF)
    }

    @Test("setRallyPoint rejects WINDTRAP (non-factory)")
    func rejectsWindtrap() {
        var pool = Simulation.StructurePool()
        let idx = pool.allocate(at: 3, type: WINDTRAP, houseID: Simulation.House.atreides)!
        #expect(!Simulation.Structures.setRallyPoint(yardIndex: idx, tile: (x: 5, y: 5), pool: &pool))
    }

    @Test("setRallyPoint rejects off-map tile")
    func rejectsOffMap() {
        var pool = Simulation.StructurePool()
        let idx = pool.allocate(at: 5, type: BARRACKS, houseID: Simulation.House.atreides)!
        #expect(!Simulation.Structures.setRallyPoint(yardIndex: idx, tile: (x: 64, y: 0), pool: &pool))
        #expect(!Simulation.Structures.setRallyPoint(yardIndex: idx, tile: (x: 0, y: -1), pool: &pool))
        #expect(pool[idx].rallyPointPacked == 0xFFFF)
    }

    @Test("setRallyPoint rejects unallocated slot")
    func rejectsUnallocated() {
        var pool = Simulation.StructurePool()
        #expect(!Simulation.Structures.setRallyPoint(yardIndex: 7, tile: (x: 5, y: 5), pool: &pool))
    }

    @Test("setRallyPoint rejects out-of-range yardIndex")
    func rejectsOutOfRange() {
        var pool = Simulation.StructurePool()
        #expect(!Simulation.Structures.setRallyPoint(yardIndex: -1, tile: (x: 5, y: 5), pool: &pool))
        #expect(!Simulation.Structures.setRallyPoint(
            yardIndex: Simulation.StructurePool.capacitySoft,
            tile: (x: 5, y: 5), pool: &pool
        ))
    }

    // MARK: completeConstruction hook

    @Test("completeConstruction without rally leaves unit idle at exit tile")
    func completionNoRallyIdle() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        let yardIdx = readyFactory(
            type: BARRACKS, at: (x: 4, y: 4), pool: &spool, produces: SOLDIER
        )
        let unitIdx = Simulation.Structures.completeConstruction(
            yardIndex: yardIdx, pool: &spool, unitPool: &upool
        )!
        #expect(upool[unitIdx].actionID != Simulation.ActionID.move)
        #expect(upool[unitIdx].targetMove == 0)
    }

    @Test("completeConstruction with rally issues orderMove on spawned unit")
    func completionWithRallyOrdersMove() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        let yardIdx = readyFactory(
            type: BARRACKS, at: (x: 4, y: 4), pool: &spool, produces: SOLDIER
        )
        _ = Simulation.Structures.setRallyPoint(
            yardIndex: yardIdx, tile: (x: 20, y: 30), pool: &spool
        )
        let unitIdx = Simulation.Structures.completeConstruction(
            yardIndex: yardIdx, pool: &spool, unitPool: &upool
        )!
        #expect(upool[unitIdx].actionID == Simulation.ActionID.move)
        let expected = Scripting.EncodedIndex.tile(packed: UInt16(30 * 64 + 20)).raw
        #expect(upool[unitIdx].targetMove == expected)
    }

    @Test("Rally persists across two builds — second unit also gets orderMove")
    func rallyPersistsAcrossBuilds() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        let yardIdx = pool2Factory(
            pool: &spool, type: LIGHT_VEHICLE, anchor: (x: 6, y: 6), produces: TRIKE
        )
        _ = Simulation.Structures.setRallyPoint(
            yardIndex: yardIdx, tile: (x: 50, y: 40), pool: &spool
        )
        // First completion
        let firstIdx = Simulation.Structures.completeConstruction(
            yardIndex: yardIdx, pool: &spool, unitPool: &upool
        )!
        // Re-ready the yard with a second queued unit.
        var slot = spool[yardIdx]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(TRIKE)
        spool[yardIdx] = slot
        let secondIdx = Simulation.Structures.completeConstruction(
            yardIndex: yardIdx, pool: &spool, unitPool: &upool
        )!
        #expect(firstIdx != secondIdx)
        #expect(upool[firstIdx].actionID == Simulation.ActionID.move)
        #expect(upool[secondIdx].actionID == Simulation.ActionID.move)
        let expected = Scripting.EncodedIndex.tile(packed: UInt16(40 * 64 + 50)).raw
        #expect(upool[firstIdx].targetMove == expected)
        #expect(upool[secondIdx].targetMove == expected)
    }

    private func pool2Factory(
        pool: inout Simulation.StructurePool, type: UInt8,
        anchor: (x: Int, y: Int), produces: UInt8
    ) -> Int {
        let idx = pool.allocate(
            in: 0...Simulation.StructurePool.capacitySoft - 1,
            type: type, houseID: Simulation.House.atreides
        )!
        var slot = pool[idx]
        slot.positionX = UInt16(anchor.x * 256)
        slot.positionY = UInt16(anchor.y * 256)
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(produces)
        pool[idx] = slot
        return idx
    }
}
