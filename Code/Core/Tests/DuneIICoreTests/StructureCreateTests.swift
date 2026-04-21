import Foundation
import Testing
@testable import DuneIICore

@Suite("Structure create — Structure_Allocate + minimal Structure_Place (non-slab / non-wall)")
struct StructureCreateTests {

    // MARK: Type IDs

    private let SLAB_1x1: UInt8 = 0
    private let SLAB_2x2: UInt8 = 1
    private let PALACE: UInt8 = 2
    private let LIGHT_VEHICLE: UInt8 = 3
    private let WINDTRAP: UInt8 = 9
    private let REFINERY: UInt8 = 12
    private let WALL: UInt8 = 14
    private let STRUCTURE_STATE_JUSTBUILT: Int16 = -1

    // MARK: Simulation.Structures.allocate

    @Test("allocate with invalidIndex + first empty pool → slot 0")
    func allocateFindFreeFirst() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.allocate(
            at: Simulation.StructurePool.invalidIndex,
            type: WINDTRAP,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == 0)
        #expect(pool[0].isUsed)
        #expect(pool[0].isAllocated)
        #expect(pool[0].type == WINDTRAP)
        #expect(pool[0].houseID == Simulation.House.atreides)
        #expect(pool[0].linkedID == 0xFF)
    }

    @Test("allocate with invalidIndex + pool with slots 0..<5 used → slot 5")
    func allocateFindFreeMiddle() {
        var pool = Simulation.StructurePool()
        for i in 0..<5 {
            _ = pool.allocate(at: i, type: WINDTRAP, houseID: Simulation.House.atreides)
        }
        let idx = Simulation.Structures.allocate(
            at: Simulation.StructurePool.invalidIndex,
            type: REFINERY,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == 5)
    }

    @Test("allocate with SLAB_1x1 always routes to reserved index 81")
    func allocateSlab1x1() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.allocate(
            at: 0,  // ignored for slabs
            type: SLAB_1x1,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == Simulation.StructurePool.indexSlab1x1)
        #expect(pool[Simulation.StructurePool.indexSlab1x1].isUsed)
    }

    @Test("allocate with SLAB_2x2 always routes to reserved index 80")
    func allocateSlab2x2() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.allocate(
            at: 0,  // ignored for slabs
            type: SLAB_2x2,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == Simulation.StructurePool.indexSlab2x2)
        #expect(pool[Simulation.StructurePool.indexSlab2x2].isUsed)
    }

    @Test("allocate with WALL always routes to reserved index 79")
    func allocateWall() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.allocate(
            at: 0,  // ignored for walls
            type: WALL,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == Simulation.StructurePool.indexWall)
        #expect(pool[Simulation.StructurePool.indexWall].isUsed)
    }

    @Test("allocate with explicit used index returns nil")
    func allocateExplicitTaken() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 3, type: WINDTRAP, houseID: Simulation.House.atreides)
        let idx = Simulation.Structures.allocate(
            at: 3,
            type: REFINERY,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == nil)
    }

    @Test("allocate with explicit free index uses that index")
    func allocateExplicitFree() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.allocate(
            at: 15,
            type: REFINERY,
            houseID: Simulation.House.harkonnen,
            pool: &pool
        )
        #expect(idx == 15)
        #expect(pool[15].isUsed)
        #expect(pool[15].type == REFINERY)
    }

    @Test("allocate on a full pool returns nil")
    func allocateFull() {
        var pool = Simulation.StructurePool()
        for i in 0..<Simulation.StructurePool.capacitySoft {
            _ = pool.allocate(at: i, type: WINDTRAP, houseID: Simulation.House.atreides)
        }
        let idx = Simulation.Structures.allocate(
            at: Simulation.StructurePool.invalidIndex,
            type: REFINERY,
            houseID: Simulation.House.atreides,
            pool: &pool
        )
        #expect(idx == nil)
    }

    // MARK: Simulation.Structures.create

    @Test("create rejects out-of-range houseID")
    func createRejectsHouseID() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: 6,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx == nil)
    }

    @Test("create rejects out-of-range type")
    func createRejectsType() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.create(
            type: 19,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx == nil)
    }

    @Test("create seeds state=JUSTBUILT, hitpoints from table, linkedID=0xFF, objectType=0xFFFF")
    func createSeedsFields() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.create(
            type: WINDTRAP,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx != nil)
        guard let index = idx else { return }
        let slot = pool[index]
        let info = Simulation.StructureInfo.table[Int(WINDTRAP)]
        #expect(slot.state == STRUCTURE_STATE_JUSTBUILT)
        #expect(slot.hitpoints == info.hitpoints)
        #expect(slot.hitpointsMax == info.hitpoints)
        #expect(slot.linkedID == 0xFF)
        #expect(slot.objectType == 0xFFFF)
        #expect(slot.countDown == 0)
        #expect(slot.upgradeLevel == 0)
        #expect(slot.type == WINDTRAP)
        #expect(slot.houseID == Simulation.House.atreides)
    }

    @Test("create for Harkonnen + LIGHT_VEHICLE seeds upgradeLevel=1")
    func createHarkonnenLightVehicleUpgrade() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.create(
            type: LIGHT_VEHICLE,
            houseID: Simulation.House.harkonnen,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx != nil)
        guard let index = idx else { return }
        #expect(pool[index].upgradeLevel == 1)
    }

    @Test("create for Atreides + LIGHT_VEHICLE keeps upgradeLevel=0 (only HK gets the pin)")
    func createAtreidesLightVehicleNoUpgrade() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.create(
            type: LIGHT_VEHICLE,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx != nil)
        guard let index = idx else { return }
        #expect(pool[index].upgradeLevel == 0)
    }

    @Test("create aligns positionX/Y to tile boundary via & 0xFF00")
    func createAlignsPosition() {
        var pool = Simulation.StructurePool()
        // Pos (0x0155, 0x0377) should align to (0x0100, 0x0300).
        let idx = Simulation.Structures.create(
            type: REFINERY,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 0x0155, y: 0x0377),
            pool: &pool
        )
        guard let index = idx else {
            Issue.record("create returned nil")
            return
        }
        #expect(pool[index].positionX == 0x0100)
        #expect(pool[index].positionY == 0x0300)
    }

    @Test("create on a full pool returns nil")
    func createFullPool() {
        var pool = Simulation.StructurePool()
        for i in 0..<Simulation.StructurePool.capacitySoft {
            _ = pool.allocate(at: i, type: WINDTRAP, houseID: Simulation.House.atreides)
        }
        let idx = Simulation.Structures.create(
            type: REFINERY,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx == nil)
    }

    @Test("create registers the slot in findArray (observable via PoolQuery)")
    func createRegistersInFindArray() {
        var pool = Simulation.StructurePool()
        let idx = Simulation.Structures.create(
            type: REFINERY,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 256, y: 256),
            pool: &pool
        )
        #expect(idx != nil)
        // PoolQuery walks findArray; our newly-created structure must appear.
        var query = Simulation.PoolQuery(houseID: Simulation.House.atreides, type: REFINERY)
        let found = pool.next(&query)
        #expect(found?.index == UInt16(idx!))
    }

    // MARK: WorldSnapshot plumbing round-trip

    @Test("WorldSnapshot loads hitpointsMax / upgradeLevel / objectType from _SAVE001.DAT")
    func saveRoundTripNewFields() throws {
        guard let install = TestInstall.locate() else { return }
        let saveURL = install.appendingPathComponent("_SAVE001.DAT")
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let data = try Data(contentsOf: saveURL)
        let game = try Formats.Save.Game.decode(data)
        let baseline = Map.empty()
        let snap = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        // Every allocated structure should have hitpointsMax matching the
        // save record. At least one should have a non-zero value.
        var anyNonZero = false
        for savedSlot in game.structures.slots {
            let idx = Int(savedSlot.object.index)
            guard idx < Simulation.StructurePool.capacitySoft else { continue }
            let simSlot = snap.structures[idx]
            guard simSlot.isUsed else { continue }
            #expect(simSlot.hitpointsMax == savedSlot.hitpointsMax)
            #expect(simSlot.upgradeLevel == savedSlot.upgradeLevel)
            #expect(simSlot.objectType == savedSlot.objectType)
            if savedSlot.hitpointsMax != 0 { anyNonZero = true }
        }
        #expect(anyNonZero, "real save should have at least one non-zero hitpointsMax")
    }
}
