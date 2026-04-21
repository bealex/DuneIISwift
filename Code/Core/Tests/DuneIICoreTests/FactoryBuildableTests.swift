import Foundation
import Testing
@testable import DuneIICore

@Suite("Factory buildable — UnitInfo fields + StructureInfo.buildableUnits + buildableUnitsFromFactory")
struct FactoryBuildableTests {

    // Unit type IDs (from UnitInfo.table indexing).
    private let CARRYALL: UInt8 = 0
    private let ORNITHOPTER: UInt8 = 1
    private let INFANTRY: UInt8 = 2
    private let TROOPERS: UInt8 = 3
    private let SOLDIER: UInt8 = 4
    private let TROOPER: UInt8 = 5
    private let LAUNCHER: UInt8 = 7
    private let DEVIATOR: UInt8 = 8
    private let TANK: UInt8 = 9
    private let SIEGE_TANK: UInt8 = 10
    private let DEVASTATOR: UInt8 = 11
    private let SONIC_TANK: UInt8 = 12
    private let TRIKE: UInt8 = 13
    private let RAIDER_TRIKE: UInt8 = 14
    private let QUAD: UInt8 = 15
    private let HARVESTER: UInt8 = 16
    private let MCV: UInt8 = 17
    private let SANDWORM: UInt8 = 25

    // Structure type IDs.
    private let PALACE: UInt8 = 2
    private let LIGHT_VEHICLE: UInt8 = 3
    private let HEAVY_VEHICLE: UInt8 = 4
    private let HIGH_TECH: UInt8 = 5
    private let WOR_TROOPER: UInt8 = 7
    private let CYARD: UInt8 = 8
    private let WINDTRAP: UInt8 = 9
    private let BARRACKS: UInt8 = 10
    private let STARPORT: UInt8 = 11
    private let REFINERY: UInt8 = 12
    private let HOUSE_OF_IX_BIT: UInt32 = 1 << 6   // type 6

    // MARK: UnitInfo new fields

    @Test("UnitInfo.availableHouse pinned for Carryall (ALL) / Launcher (59 - no Ordos) / Devastator (57) / Sandworm (FREMEN)")
    func unitAvailableHousePinned() {
        let all: UInt8 = 0b0011_1111
        #expect(Simulation.UnitInfo.table[Int(CARRYALL)].availableHouse == all)
        #expect(Simulation.UnitInfo.table[Int(LAUNCHER)].availableHouse == 0b0011_1011) // no Ordos
        #expect(Simulation.UnitInfo.table[Int(DEVASTATOR)].availableHouse == 0b0011_1001) // no Ordos, no Atreides
        #expect(Simulation.UnitInfo.table[Int(SANDWORM)].availableHouse == 0b0000_1000)   // Fremen only
    }

    @Test("UnitInfo.structuresRequired: Thopter / Deviator / Devastator / Sonic Tank require HOUSE_OF_IX")
    func unitStructuresRequiredIX() {
        #expect(Simulation.UnitInfo.table[Int(ORNITHOPTER)].structuresRequired == HOUSE_OF_IX_BIT)
        #expect(Simulation.UnitInfo.table[Int(DEVIATOR)].structuresRequired == HOUSE_OF_IX_BIT)
        #expect(Simulation.UnitInfo.table[Int(DEVASTATOR)].structuresRequired == HOUSE_OF_IX_BIT)
        #expect(Simulation.UnitInfo.table[Int(SONIC_TANK)].structuresRequired == HOUSE_OF_IX_BIT)
        // Tank / Carryall have no prereq.
        #expect(Simulation.UnitInfo.table[Int(TANK)].structuresRequired == 0)
        #expect(Simulation.UnitInfo.table[Int(CARRYALL)].structuresRequired == 0)
    }

    @Test("UnitInfo.upgradeLevelRequired: Siege Tank=3, Launcher=2, Quad/MCV/Infantry/Troopers/Thopter=1, rest=0")
    func unitUpgradeLevelRequired() {
        #expect(Simulation.UnitInfo.table[Int(SIEGE_TANK)].upgradeLevelRequired == 3)
        #expect(Simulation.UnitInfo.table[Int(LAUNCHER)].upgradeLevelRequired == 2)
        #expect(Simulation.UnitInfo.table[Int(QUAD)].upgradeLevelRequired == 1)
        #expect(Simulation.UnitInfo.table[Int(MCV)].upgradeLevelRequired == 1)
        #expect(Simulation.UnitInfo.table[Int(INFANTRY)].upgradeLevelRequired == 1)
        #expect(Simulation.UnitInfo.table[Int(TROOPERS)].upgradeLevelRequired == 1)
        #expect(Simulation.UnitInfo.table[Int(ORNITHOPTER)].upgradeLevelRequired == 1)
        #expect(Simulation.UnitInfo.table[Int(SOLDIER)].upgradeLevelRequired == 0)
        #expect(Simulation.UnitInfo.table[Int(CARRYALL)].upgradeLevelRequired == 0)
    }

    // MARK: StructureInfo.buildableUnits

    @Test("LIGHT_VEHICLE buildableUnits = [TRIKE, QUAD, -, -, -, -, -, -]")
    func buildableUnitsLightVehicle() {
        let row = Simulation.StructureInfo.table[Int(LIGHT_VEHICLE)]
        #expect(row.buildableUnits == [13, 15, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("HEAVY_VEHICLE buildableUnits fills all 8 slots")
    func buildableUnitsHeavyVehicle() {
        let row = Simulation.StructureInfo.table[Int(HEAVY_VEHICLE)]
        #expect(row.buildableUnits == [10, 7, 16, 9, 11, 8, 17, 12])
    }

    @Test("BARRACKS buildableUnits = [SOLDIER, INFANTRY, -, -, -, -, -, -]")
    func buildableUnitsBarracks() {
        let row = Simulation.StructureInfo.table[Int(BARRACKS)]
        #expect(row.buildableUnits == [4, 2, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("HIGH_TECH buildableUnits = [CARRYALL, ORNITHOPTER, -, -, -, -, -, -]")
    func buildableUnitsHiTech() {
        let row = Simulation.StructureInfo.table[Int(HIGH_TECH)]
        #expect(row.buildableUnits == [0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("WOR_TROOPER buildableUnits = [TROOPER, TROOPERS, -, -, -, -, -, -]")
    func buildableUnitsWor() {
        let row = Simulation.StructureInfo.table[Int(WOR_TROOPER)]
        #expect(row.buildableUnits == [5, 3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("Non-factory structures default to buildableUnits = [0xFF × 8]")
    func buildableUnitsNonFactoriesEmpty() {
        for typeID in [0, 1, 2, 6, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18] {
            let row = Simulation.StructureInfo.table[typeID]
            #expect(row.buildableUnits == Array(repeating: 0xFF, count: 8),
                    "type \(typeID) expected empty buildableUnits")
        }
    }

    // MARK: buildableUnitsFromFactory

    @Test("Atreides LV factory, upgradeLevel=0, no IX: TRIKE present, QUAD absent (upgrade-gated)")
    func atreidesLVZeroUpgradeLevel() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: LIGHT_VEHICLE,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(TRIKE))) != 0)
        #expect((mask & (UInt32(1) << UInt32(QUAD))) == 0)
    }

    @Test("Atreides LV factory, upgradeLevel=1: TRIKE and QUAD both available")
    func atreidesLVOneUpgradeLevel() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: LIGHT_VEHICLE,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 1,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(TRIKE))) != 0)
        #expect((mask & (UInt32(1) << UInt32(QUAD))) != 0)
    }

    @Test("Harkonnen LV factory, upgradeLevel=1 (HK pin): no TRIKE (availableHouse excludes HK), QUAD present")
    func harkonnenLVNoTrike() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: LIGHT_VEHICLE,
            factoryHouseID: Simulation.House.harkonnen,
            factoryUpgradeLevel: 1,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(TRIKE))) == 0)
        #expect((mask & (UInt32(1) << UInt32(QUAD))) != 0)
    }

    @Test("Ordos LV factory, upgradeLevel=0: RAIDER_TRIKE substituted for TRIKE; TRIKE not in mask")
    func ordosLVRaiderTrike() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: LIGHT_VEHICLE,
            factoryHouseID: Simulation.House.ordos,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(RAIDER_TRIKE))) != 0)
        // The TRIKE slot was substituted; TRIKE itself is not available to Ordos.
        #expect((mask & (UInt32(1) << UInt32(TRIKE))) == 0)
    }

    @Test("Atreides HV factory, upgradeLevel=0, no IX: HARVESTER + TANK only")
    func atreidesHVBasics() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: HEAVY_VEHICLE,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(HARVESTER))) != 0)
        #expect((mask & (UInt32(1) << UInt32(TANK))) != 0)
        // MCV requires upgradeLevel 1.
        #expect((mask & (UInt32(1) << UInt32(MCV))) == 0)
        // SIEGE_TANK requires upgradeLevel 3.
        #expect((mask & (UInt32(1) << UInt32(SIEGE_TANK))) == 0)
        // DEVASTATOR requires IX.
        #expect((mask & (UInt32(1) << UInt32(DEVASTATOR))) == 0)
        // DEVIATOR is Ordos-only.
        #expect((mask & (UInt32(1) << UInt32(DEVIATOR))) == 0)
    }

    @Test("Atreides HV factory, upgradeLevel=3, with IX: DEVASTATOR absent (HOUSE_ATREIDES excluded); SONIC_TANK present")
    func atreidesHVLateGame() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: HEAVY_VEHICLE,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 3,
            structuresBuilt: HOUSE_OF_IX_BIT
        )
        #expect((mask & (UInt32(1) << UInt32(SONIC_TANK))) != 0)  // Atreides-only, needs IX
        #expect((mask & (UInt32(1) << UInt32(DEVASTATOR))) == 0)  // not available to Atreides
        #expect((mask & (UInt32(1) << UInt32(DEVIATOR))) == 0)    // Ordos-only
        #expect((mask & (UInt32(1) << UInt32(SIEGE_TANK))) != 0)  // upgradeLevel 3 ≥ 3
    }

    @Test("Ordos HV factory, upgradeLevel=2: SIEGE_TANK present (Ordos -1 relaxation makes requirement 2)")
    func ordosSiegeTankBonus() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: HEAVY_VEHICLE,
            factoryHouseID: Simulation.House.ordos,
            factoryUpgradeLevel: 2,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(SIEGE_TANK))) != 0)
    }

    @Test("Ordos HV factory, upgradeLevel=1: SIEGE_TANK still absent (relaxed to 2, but factory is only 1)")
    func ordosSiegeTankStillGated() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: HEAVY_VEHICLE,
            factoryHouseID: Simulation.House.ordos,
            factoryUpgradeLevel: 1,
            structuresBuilt: 0
        )
        #expect((mask & (UInt32(1) << UInt32(SIEGE_TANK))) == 0)
    }

    @Test("Ordos HV factory, upgradeLevel=0: DEVIATOR absent (needs IX); with IX: present")
    func ordosDeviatorIXGate() {
        let withoutIX = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: HEAVY_VEHICLE,
            factoryHouseID: Simulation.House.ordos,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect((withoutIX & (UInt32(1) << UInt32(DEVIATOR))) == 0)
        let withIX = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: HEAVY_VEHICLE,
            factoryHouseID: Simulation.House.ordos,
            factoryUpgradeLevel: 0,
            structuresBuilt: HOUSE_OF_IX_BIT
        )
        #expect((withIX & (UInt32(1) << UInt32(DEVIATOR))) != 0)
    }

    @Test("BARRACKS (Atreides): SOLDIER + INFANTRY flow with upgradeLevel")
    func barracksAtreidesBasic() {
        let mask0 = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: BARRACKS,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        // SOLDIER upgradeLevelRequired=0 → in mask.
        #expect((mask0 & (UInt32(1) << UInt32(SOLDIER))) != 0)
        // INFANTRY upgradeLevelRequired=1 → NOT in mask at upgradeLevel 0.
        #expect((mask0 & (UInt32(1) << UInt32(INFANTRY))) == 0)
        let mask1 = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: BARRACKS,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 1,
            structuresBuilt: 0
        )
        #expect((mask1 & (UInt32(1) << UInt32(INFANTRY))) != 0)
    }

    @Test("Non-factory structure type (REFINERY) returns 0")
    func nonFactoryReturnsZero() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: REFINERY,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect(mask == 0)
    }

    @Test("STARPORT returns 0 (deferred; OpenDUNE uses -1 sentinel which needs g_starportAvailable)")
    func starportReturnsZero() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: STARPORT,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect(mask == 0)
    }

    @Test("CYARD (index 8) not a factory in this sense: returns 0")
    func cyardIsNotFactory() {
        let mask = Simulation.Structures.buildableUnitsFromFactory(
            factoryType: CYARD,
            factoryHouseID: Simulation.House.atreides,
            factoryUpgradeLevel: 0,
            structuresBuilt: 0
        )
        #expect(mask == 0)
    }

    // MARK: Slice 5b — selectableYardAt + relaxed startConstruction

    @Test("selectableYardAt: empty pool → nil")
    func selectableEmpty() {
        let pool = Simulation.StructurePool()
        let idx = Simulation.Structures.selectableYardAt(
            tileX: 5, tileY: 5, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(idx == nil)
    }

    @Test("selectableYardAt: player-owned CYARD covers tile → returns slot index")
    func selectableCyardHit() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        // CY is 2x2: covers (5,5), (6,5), (5,6), (6,6).
        let hit = Simulation.Structures.selectableYardAt(
            tileX: 6, tileY: 5, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(hit == 0)
    }

    @Test("selectableYardAt: player-owned LIGHT_VEHICLE factory covers tile → returns slot index")
    func selectableLVHit() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: LIGHT_VEHICLE,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        let hit = Simulation.Structures.selectableYardAt(
            tileX: 11, tileY: 11, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(hit == 0)
    }

    @Test("selectableYardAt: REFINERY is not a selectable yard → nil")
    func selectableRefineryMiss() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: REFINERY,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        let hit = Simulation.Structures.selectableYardAt(
            tileX: 10, tileY: 10, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(hit == nil)
    }

    @Test("selectableYardAt: enemy-owned CYARD → nil (not player-owned)")
    func selectableEnemyCyardMiss() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.harkonnen,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        let hit = Simulation.Structures.selectableYardAt(
            tileX: 5, tileY: 5, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(hit == nil)
    }

    @Test("selectableYardAt: click outside any footprint → nil")
    func selectableOutsideMiss() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        let hit = Simulation.Structures.selectableYardAt(
            tileX: 20, tileY: 20, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(hit == nil)
    }

    @Test("selectableYardAt: STARPORT is NOT selectable in slice 5b")
    func selectableStarportMiss() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: STARPORT,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        let hit = Simulation.Structures.selectableYardAt(
            tileX: 10, tileY: 10, pool: pool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(hit == nil)
    }

    // MARK: Slice 5b — startConstruction relaxed to factory yards

    @Test("startConstruction on LIGHT_VEHICLE factory with TRIKE unit type: returns true, flips BUSY")
    func startConstructionFactoryTrike() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: LIGHT_VEHICLE,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: 13 /* TRIKE */, pool: &pool
        )
        #expect(ok)
        #expect(pool[0].state == Simulation.StructureState.busy.rawValue)
        #expect(pool[0].objectType == 13)
    }

    @Test("startConstruction on BARRACKS with SOLDIER: returns true, flips BUSY")
    func startConstructionBarracksSoldier() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: 4 /* SOLDIER */, pool: &pool
        )
        #expect(ok)
        #expect(pool[0].state == Simulation.StructureState.busy.rawValue)
    }

    @Test("startConstruction on REFINERY (not a factory or CY): returns false")
    func startConstructionRefineryRejected() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: REFINERY,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: 4, pool: &pool
        )
        #expect(!ok)
    }

    // MARK: UnitInfo.buildableUnitTypes helper

    @Test("UnitInfo.buildableUnitTypes on empty mask → []")
    func unitBuildableEmpty() {
        #expect(Simulation.UnitInfo.buildableUnitTypes(from: 0) == [])
    }

    @Test("UnitInfo.buildableUnitTypes in ascending type-ID order")
    func unitBuildableAscending() {
        // SOLDIER=4, INFANTRY=2 → [2, 4] ascending.
        let mask: UInt32 = (1 << 4) | (1 << 2)
        #expect(Simulation.UnitInfo.buildableUnitTypes(from: mask) == [2, 4])
    }

    @Test("UnitInfo.buildableUnitTypes ignores bits 27..31")
    func unitBuildableIgnoresHighBits() {
        let mask: UInt32 = 0xFFFF_FFFF
        let all: [UInt8] = Array(0...26)
        #expect(Simulation.UnitInfo.buildableUnitTypes(from: mask) == all)
    }
}
