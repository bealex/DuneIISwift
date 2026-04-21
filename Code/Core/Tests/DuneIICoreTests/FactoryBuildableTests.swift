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

    // MARK: Slice 5b-build — UnitInfo.buildTime + dispatch + completion

    @Test("UnitInfo.buildTime pinned for Carryall=64, Soldier=32, Siege Tank=96, projectiles=0")
    func unitBuildTimePinned() {
        #expect(Simulation.UnitInfo.table[Int(CARRYALL)].buildTime == 64)
        #expect(Simulation.UnitInfo.table[Int(SOLDIER)].buildTime == 32)
        #expect(Simulation.UnitInfo.table[Int(SIEGE_TANK)].buildTime == 96)
        #expect(Simulation.UnitInfo.table[Int(TRIKE)].buildTime == 40)
        // Projectiles (18+) all zero.
        for i in 18...26 {
            #expect(Simulation.UnitInfo.table[i].buildTime == 0, "unit \(i)")
        }
    }

    @Test("LV factory startConstruction with TRIKE uses unit buildTime (40<<8 = 10240), not yard")
    func startConstructionDispatchesUnitBuildTime() {
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
        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: TRIKE, pool: &pool
        )
        // TRIKE buildTime = 40 → countDown = 40 << 8 = 10240.
        #expect(pool[0].countDown == 10240)
    }

    @Test("BARRACKS startConstruction with SOLDIER uses unit buildTime (32<<8 = 8192)")
    func startConstructionBarracksSoldierUnitBuildTime() {
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
        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: SOLDIER, pool: &pool
        )
        #expect(pool[0].countDown == 8192)
    }

    @Test("CY startConstruction still uses produced-structure buildTime (WINDTRAP = 48<<8 = 12288)")
    func startConstructionCYUnchanged() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: 9 /* WINDTRAP */, pool: &pool
        )
        // WINDTRAP buildTime = 48 → 12288.
        #expect(pool[0].countDown == 12288)
    }

    // MARK: Simulation.Units.createUnit

    @Test("Units.createUnit valid input returns non-nil index + seeds slot")
    func createUnitValid() {
        var units = Simulation.UnitPool()
        let idx = Simulation.Units.createUnit(
            type: SOLDIER,
            houseID: Simulation.House.atreides,
            tileX: 10, tileY: 10,
            pool: &units
        )
        #expect(idx != nil)
        guard let index = idx else { return }
        let slot = units[index]
        #expect(slot.isUsed)
        #expect(slot.type == SOLDIER)
        #expect(slot.houseID == Simulation.House.atreides)
        #expect(slot.positionX == 10 * 256 + 128)  // centered pos32
        #expect(slot.positionY == 10 * 256 + 128)
        #expect(slot.hitpoints == Simulation.UnitInfo.table[Int(SOLDIER)].hitpoints)
        #expect(slot.seenByHouses == 0xFF)
    }

    @Test("Units.createUnit out-of-range houseID → nil")
    func createUnitBadHouse() {
        var units = Simulation.UnitPool()
        let idx = Simulation.Units.createUnit(
            type: SOLDIER, houseID: 6, tileX: 10, tileY: 10, pool: &units
        )
        #expect(idx == nil)
    }

    @Test("Units.createUnit out-of-range type → nil")
    func createUnitBadType() {
        var units = Simulation.UnitPool()
        let idx = Simulation.Units.createUnit(
            type: 27, houseID: Simulation.House.atreides,
            tileX: 10, tileY: 10, pool: &units
        )
        #expect(idx == nil)
    }

    // MARK: Simulation.Structures.completeConstruction

    @Test("completeConstruction on READY BARRACKS spawns a SOLDIER south of factory; yard flips IDLE")
    func completeBarracksSoldier() {
        var structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        // Manually flip yard to READY with SOLDIER queued.
        var slot = structures[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(SOLDIER)
        slot.countDown = 0
        structures[0] = slot

        let unitIdx = Simulation.Structures.completeConstruction(
            yardIndex: 0, pool: &structures, unitPool: &units
        )
        #expect(unitIdx != nil)
        if let ui = unitIdx {
            #expect(units[ui].type == SOLDIER)
            #expect(units[ui].houseID == Simulation.House.atreides)
            // Slice 5c: spawn tile is south of footprint. BARRACKS is
            // 2x2 at (5, 5) → spawn tile (5, 7) → pos32 (5*256+128,
            // 7*256+128) = (1408, 1920).
            #expect(units[ui].positionX == 5 * 256 + 128)
            #expect(units[ui].positionY == 7 * 256 + 128)
        }
        #expect(structures[0].state == Simulation.StructureState.idle.rawValue)
        #expect(structures[0].objectType == 0xFFFF)
        #expect(structures[0].countDown == 0)
    }

    @Test("completeConstruction on BUSY factory returns nil without mutation")
    func completeBusyNoOp() {
        var structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        var slot = structures[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.objectType = UInt16(SOLDIER)
        slot.countDown = 5000
        structures[0] = slot
        let before = structures[0]

        let result = Simulation.Structures.completeConstruction(
            yardIndex: 0, pool: &structures, unitPool: &units
        )
        #expect(result == nil)
        #expect(structures[0] == before)
        #expect(units.findArray.isEmpty)
    }

    @Test("completeConstruction on READY CYARD returns nil (CY completion is click-to-place)")
    func completeCYReturnsNil() {
        var structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        var slot = structures[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = 9 /* WINDTRAP */
        structures[0] = slot

        let result = Simulation.Structures.completeConstruction(
            yardIndex: 0, pool: &structures, unitPool: &units
        )
        #expect(result == nil)
        // Yard state untouched (CY completion doesn't reset here).
        #expect(structures[0].state == Simulation.StructureState.ready.rawValue)
    }

    @Test("completeConstruction on REFINERY returns nil")
    func completeRefineryReturnsNil() {
        var structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: REFINERY,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        var slot = structures[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(SOLDIER)
        structures[0] = slot

        let result = Simulation.Structures.completeConstruction(
            yardIndex: 0, pool: &structures, unitPool: &units
        )
        #expect(result == nil)
    }

    // MARK: Slice 5c — cancelConstruction

    @Test("cancelConstruction on BUSY yard → true, state → IDLE, objectType/countDown reset")
    func cancelBusy() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.objectType = UInt16(SOLDIER)
        slot.countDown = 5000
        pool[0] = slot

        let ok = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        #expect(ok)
        #expect(pool[0].state == Simulation.StructureState.idle.rawValue)
        #expect(pool[0].objectType == 0xFFFF)
        #expect(pool[0].countDown == 0)
    }

    @Test("cancelConstruction on READY yard → true, reset (OpenDUNE parity — cancels pre-completed item)")
    func cancelReady() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        _ = Simulation.Structures.create(
            type: LIGHT_VEHICLE,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(TRIKE)
        slot.countDown = 0
        pool[0] = slot

        let ok = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        #expect(ok)
        #expect(pool[0].state == Simulation.StructureState.idle.rawValue)
        #expect(pool[0].objectType == 0xFFFF)
    }

    @Test("cancelConstruction on IDLE yard → false, no mutation")
    func cancelIdleRejected() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        let before = pool[0]

        let ok = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        #expect(!ok)
        #expect(pool[0] == before)
    }

    // MARK: Slice 6b — cancel refund

    @Test("cancel refund: fresh BUSY WINDTRAP (no ticks spent) → 0 refund")
    func cancelRefundFresh() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 500
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: 8 /* CYARD */,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.objectType = 9 /* WINDTRAP */
        slot.countDown = 12288  // fresh — 48 << 8, no ticks spent
        pool[0] = slot

        _ = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        // Refund = 0 on fresh cancel.
        #expect(houses[Int(Simulation.House.atreides)].credits == 500)
    }

    @Test("cancel refund: half-built WINDTRAP (countDown=6144) → 150 refund")
    func cancelRefundHalf() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 500
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: 8 /* CYARD */,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.objectType = 9 /* WINDTRAP */
        slot.countDown = 6144  // halfway (24 << 8)
        pool[0] = slot

        _ = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        // ticksSpent = 48 - 24 = 24; refund = 24 * 300 / 48 = 150.
        #expect(houses[Int(Simulation.House.atreides)].credits == 650)
    }

    @Test("cancel refund: READY WINDTRAP (countDown=0) → full 300 refund")
    func cancelRefundReady() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 500
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: 8 /* CYARD */,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = 9 /* WINDTRAP */
        slot.countDown = 0
        pool[0] = slot

        _ = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        // ticksSpent = 48; refund = 48 * 300 / 48 = 300.
        #expect(houses[Int(Simulation.House.atreides)].credits == 800)
    }

    // MARK: Slice 6c — UnitInfo.buildCredits + factory drain / refund

    @Test("UnitInfo.buildCredits pinned: Carryall=800, MCV=900, Soldier=60, Sandworm=0")
    func unitBuildCreditsTable() {
        #expect(Simulation.UnitInfo.table[Int(CARRYALL)].buildCredits == 800)
        #expect(Simulation.UnitInfo.table[Int(MCV)].buildCredits == 900)
        #expect(Simulation.UnitInfo.table[Int(SOLDIER)].buildCredits == 60)
        #expect(Simulation.UnitInfo.table[Int(TRIKE)].buildCredits == 150)
        #expect(Simulation.UnitInfo.table[Int(SIEGE_TANK)].buildCredits == 600)
        #expect(Simulation.UnitInfo.table[Int(SANDWORM)].buildCredits == 0)
    }

    @Test("factory drain: BARRACKS + SOLDIER (60/32 = 1 credit/tick)")
    func factoryDrainBarracks() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 1000
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: SOLDIER, pool: &pool
        )
        // One tick: credits -= 1, countDown -= 256.
        Simulation.Structures.tickConstruction(pool: &pool, houses: &houses)
        #expect(houses[Int(Simulation.House.atreides)].credits == 999)
    }

    @Test("factory drain: LV + TRIKE (150/40 = 3 credits/tick)")
    func factoryDrainLVTrike() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 1000
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: LIGHT_VEHICLE,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 10 * 256, y: 10 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot
        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: TRIKE, pool: &pool
        )
        Simulation.Structures.tickConstruction(pool: &pool, houses: &houses)
        #expect(houses[Int(Simulation.House.atreides)].credits == 997)
    }

    @Test("factory drain pauses on insufficient credits (same as CY)")
    func factoryDrainPauses() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        // credits default 0 after allocate

        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: SOLDIER, pool: &pool
        )
        let countDownBefore = pool[0].countDown
        Simulation.Structures.tickConstruction(pool: &pool, houses: &houses)
        #expect(houses[Int(Simulation.House.atreides)].credits == 0)
        #expect(pool[0].countDown == countDownBefore)
        #expect(pool[0].state == Simulation.StructureState.busy.rawValue)
    }

    @Test("factory cancel refund: half-built BARRACKS + SOLDIER → 30 refund")
    func factoryCancelRefundHalf() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 500
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.objectType = UInt16(SOLDIER)
        // SOLDIER buildTime = 32, half-built at countDown = 16 << 8 = 4096
        slot.countDown = 4096
        pool[0] = slot

        _ = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        // ticksSpent = 32 - 16 = 16; refund = 16 * 60 / 32 = 30.
        #expect(houses[Int(Simulation.House.atreides)].credits == 530)
    }

    @Test("cancel refund: objectType=0xFFFF → no refund math (safe no-op on credits)")
    func cancelRefundUnsetObjectType() {
        var pool = Simulation.StructurePool()
        var houses = Simulation.HousePool()
        houses.allocate(at: Int(Simulation.House.atreides))
        var atreides = houses[Int(Simulation.House.atreides)]
        atreides.credits = 500
        houses[Int(Simulation.House.atreides)] = atreides

        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        // objectType stays 0xFFFF
        slot.countDown = 5000
        pool[0] = slot

        _ = Simulation.Structures.cancelConstruction(
            yardIndex: 0, pool: &pool, houses: &houses
        )
        // No refund math with objectType unset.
        #expect(houses[Int(Simulation.House.atreides)].credits == 500)
        // State still resets.
        #expect(pool[0].state == Simulation.StructureState.idle.rawValue)
    }

    // MARK: Slice 5c — factorySpawnTile

    @Test("factorySpawnTile for BARRACKS (2x2) at (5, 5) → (5, 7) south of footprint")
    func spawnTileBarracks() {
        let t = Simulation.Structures.factorySpawnTile(
            yardType: BARRACKS, anchorX: 5, anchorY: 5
        )
        #expect(t.x == 5)
        #expect(t.y == 7)
    }

    @Test("factorySpawnTile for HEAVY_VEHICLE (3x2) at (10, 10) → (10, 12)")
    func spawnTileHV() {
        let t = Simulation.Structures.factorySpawnTile(
            yardType: HEAVY_VEHICLE, anchorX: 10, anchorY: 10
        )
        #expect(t.x == 10)
        #expect(t.y == 12)
    }

    @Test("factorySpawnTile fallback to anchor when south is out of bounds")
    func spawnTileFallback() {
        // HV (3x2) at (10, 62) → exit y = 64 out of range → anchor.
        let t = Simulation.Structures.factorySpawnTile(
            yardType: HEAVY_VEHICLE, anchorX: 10, anchorY: 62
        )
        #expect(t.x == 10)
        #expect(t.y == 62)
    }

    @Test("completeConstruction spawns unit at factorySpawnTile (south of factory), not anchor")
    func completeAtSpawnTile() {
        var structures = Simulation.StructurePool()
        var units = Simulation.UnitPool()
        _ = Simulation.Structures.create(
            type: BARRACKS,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &structures
        )
        var slot = structures[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.objectType = UInt16(SOLDIER)
        structures[0] = slot

        guard let unitIdx = Simulation.Structures.completeConstruction(
            yardIndex: 0, pool: &structures, unitPool: &units
        ) else {
            Issue.record("completeConstruction returned nil")
            return
        }
        // Anchor = (5, 5), 2x2 footprint → spawn at (5, 7)
        // → pos32 (5*256+128, 7*256+128) = (1408, 1920).
        #expect(units[unitIdx].positionX == 5 * 256 + 128)
        #expect(units[unitIdx].positionY == 7 * 256 + 128)
    }
}
