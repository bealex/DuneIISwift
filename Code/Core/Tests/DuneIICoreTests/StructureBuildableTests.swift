import Foundation
import Testing
@testable import DuneIICore

@Suite("Structure buildable — structuresBuilt + Structure_GetBuildable (yard case)")
struct StructureBuildableTests {

    // MARK: Type IDs (mirror Scenario.StructureType extension properties)

    private let SLAB_1x1: UInt8 = 0
    private let SLAB_2x2: UInt8 = 1
    private let PALACE: UInt8 = 2
    private let LIGHT_VEHICLE: UInt8 = 3
    private let HEAVY_VEHICLE: UInt8 = 4
    private let HIGH_TECH: UInt8 = 5
    private let HOUSE_OF_IX: UInt8 = 6
    private let WOR_TROOPER: UInt8 = 7
    private let CONSTRUCTION_YARD: UInt8 = 8
    private let WINDTRAP: UInt8 = 9
    private let BARRACKS: UInt8 = 10
    private let STARPORT: UInt8 = 11
    private let REFINERY: UInt8 = 12
    private let REPAIR: UInt8 = 13
    private let WALL: UInt8 = 14
    private let TURRET: UInt8 = 15
    private let ROCKET_TURRET: UInt8 = 16
    private let SILO: UInt8 = 17
    private let OUTPOST: UInt8 = 18

    // MARK: StructureInfo — new fields populated

    @Test("StructureInfo carries availableCampaign/House + structuresRequired + upgradeLevelRequired for every type")
    func newFieldsPresent() {
        let table = Simulation.StructureInfo.table

        // Full table populated.
        #expect(table.count == 19)

        // Mission-1 unlocks: WINDTRAP, REFINERY, SLAB_1x1 all have availableCampaign == 1.
        #expect(table[Int(WINDTRAP)].availableCampaign == 1)
        #expect(table[Int(REFINERY)].availableCampaign == 1)
        #expect(table[Int(SLAB_1x1)].availableCampaign == 1)

        // Never-unlocks: CONSTRUCTION_YARD is 99.
        #expect(table[Int(CONSTRUCTION_YARD)].availableCampaign == 99)

        // ROCKET_TURRET needs upgradeLevelRequired == 2 (the only >0 non-slab).
        #expect(table[Int(ROCKET_TURRET)].upgradeLevelRequired == 2)
        #expect(table[Int(SLAB_2x2)].upgradeLevelRequired == 1)
        #expect(table[Int(WINDTRAP)].upgradeLevelRequired == 0)

        // House bitmasks: BARRACKS excludes Harkonnen (bit 0).
        #expect((table[Int(BARRACKS)].availableHouse & 0b1) == 0)
        #expect(table[Int(BARRACKS)].availableHouse == 0b00111110)
        // WOR_TROOPER excludes Atreides (bit 1).
        #expect((table[Int(WOR_TROOPER)].availableHouse & 0b10) == 0)
        #expect(table[Int(WOR_TROOPER)].availableHouse == 0b00111101)
        // Palace is all-houses.
        #expect(table[Int(PALACE)].availableHouse == 0b00111111)

        // Prerequisites: LIGHT_VEHICLE needs REFINERY + WINDTRAP.
        let lvReq = table[Int(LIGHT_VEHICLE)].structuresRequired
        #expect((lvReq & (1 << REFINERY)) != 0)
        #expect((lvReq & (1 << WINDTRAP)) != 0)
        #expect((lvReq & ~((1 << REFINERY) | (1 << WINDTRAP))) == 0)

        // CONSTRUCTION_YARD uses FLAG_STRUCTURE_NEVER.
        #expect(table[Int(CONSTRUCTION_YARD)].structuresRequired == 0x80000000)
    }

    // MARK: structuresBuilt

    @Test("structuresBuilt on an empty pool is 0")
    func structuresBuiltEmpty() {
        let pool = Simulation.StructurePool()
        #expect(Simulation.Structures.structuresBuilt(houseID: Simulation.House.atreides, pool: pool) == 0)
    }

    @Test("structuresBuilt OR's in each allocated non-slab non-wall structure of the house")
    func structuresBuiltOR() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 0, type: WINDTRAP, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 1, type: REFINERY, houseID: Simulation.House.atreides)
        let mask = Simulation.Structures.structuresBuilt(houseID: Simulation.House.atreides, pool: pool)
        #expect(mask == ((1 << WINDTRAP) | (1 << REFINERY)))
    }

    @Test("structuresBuilt excludes slabs and walls")
    func structuresBuiltSkipsSlabsAndWalls() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 0, type: SLAB_1x1, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 1, type: SLAB_2x2, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 2, type: WALL, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 3, type: WINDTRAP, houseID: Simulation.House.atreides)
        let mask = Simulation.Structures.structuresBuilt(houseID: Simulation.House.atreides, pool: pool)
        #expect(mask == (1 << WINDTRAP))
    }

    @Test("structuresBuilt filters by houseID")
    func structuresBuiltPerHouse() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 0, type: WINDTRAP, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 1, type: REFINERY, houseID: Simulation.House.harkonnen)
        #expect(Simulation.Structures.structuresBuilt(houseID: Simulation.House.atreides, pool: pool)
                == (1 << WINDTRAP))
        #expect(Simulation.Structures.structuresBuilt(houseID: Simulation.House.harkonnen, pool: pool)
                == (1 << REFINERY))
        #expect(Simulation.Structures.structuresBuilt(houseID: Simulation.House.ordos, pool: pool) == 0)
    }

    // MARK: buildableStructuresFromYard — campaign / house gates

    @Test("mission-1 Harkonnen AI yard (not player) skips prereqs; returns campaign-1 set")
    func buildableAIYardMission1() {
        // AI: yardHouseID != playerHouseID. Prereqs ignored.
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: 0,
            campaignID: 0,
            playerHouseID: Simulation.House.atreides
        )
        // Campaign 1 unlocks: SLAB_1x1, WINDTRAP, REFINERY. WOR_TROOPER is c5 so still out.
        #expect((mask & (1 << SLAB_1x1)) != 0)
        #expect((mask & (1 << WINDTRAP)) != 0)
        #expect((mask & (1 << REFINERY)) != 0)
        #expect((mask & (1 << WOR_TROOPER)) == 0)
        #expect((mask & (1 << BARRACKS)) == 0)  // c2 gate
        #expect((mask & (1 << CONSTRUCTION_YARD)) == 0)  // NEVER
    }

    @Test("mission-1 Harkonnen player yard, empty build: only SLAB_1x1 + WINDTRAP (REFINERY needs WINDTRAP prereq)")
    func buildablePlayerYardEmpty() {
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: 0,
            campaignID: 0,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((mask & (1 << SLAB_1x1)) != 0)
        #expect((mask & (1 << WINDTRAP)) != 0)
        // REFINERY requires a WINDTRAP that isn't built; player-yard enforces prereqs.
        #expect((mask & (1 << REFINERY)) == 0)
    }

    @Test("mission-1 Harkonnen player yard with WINDTRAP built: REFINERY unlocks")
    func buildablePlayerYardWithWindtrap() {
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: (1 << WINDTRAP),
            campaignID: 0,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((mask & (1 << REFINERY)) != 0)
    }

    @Test("Atreides player yard at campaign 4 with all prereqs: BARRACKS available, WOR_TROOPER is not")
    func buildableAtreidesNoWor() {
        // All structures built so every prereq is satisfied.
        let allBuilt: UInt32 = 0x0007_FFFF  // bits 0..18
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 2,
            structuresBuilt: allBuilt,
            campaignID: 4,
            playerHouseID: Simulation.House.atreides
        )
        #expect((mask & (1 << BARRACKS)) != 0)
        // WOR_TROOPER's availableHouse excludes Atreides.
        #expect((mask & (1 << WOR_TROOPER)) == 0)
    }

    @Test("Harkonnen BARRACKS forever excluded: availableHouse has no Harkonnen bit")
    func harkonnenNoBarracks() {
        let allBuilt: UInt32 = 0x0007_FFFF
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 2,
            structuresBuilt: allBuilt,
            campaignID: 8,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((mask & (1 << BARRACKS)) == 0)
    }

    @Test("Harkonnen player yard at campaign 2 with no BARRACKS: WOR_TROOPER still available (Harkonnen exception)")
    func harkonnenWorException() {
        // Harkonnen has OUTPOST + WINDTRAP but no BARRACKS. WOR normally needs
        // OUTPOST | BARRACKS | WINDTRAP. The exception clears the BARRACKS bit.
        // The exception also pins availableCampaign to 2, so campaignID=1 passes.
        let built: UInt32 = (1 << OUTPOST) | (1 << WINDTRAP)
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 1,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((mask & (1 << WOR_TROOPER)) != 0)
    }

    @Test("LIGHT_VEHICLE not available at campaign 0 for any player yard")
    func lightVehicleMission1Gate() {
        // Even with REFINERY + WINDTRAP built and campaign=0: LIGHT_VEHICLE
        // has availableCampaign=3 (Harkonnen) / pinned-to-2 (non-Harkonnen).
        // Either way, gate fails at campaign 0.
        let built: UInt32 = (1 << REFINERY) | (1 << WINDTRAP)
        let atreidesMask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 0,
            playerHouseID: Simulation.House.atreides
        )
        let harkMask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 0,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((atreidesMask & (1 << LIGHT_VEHICLE)) == 0)
        #expect((harkMask & (1 << LIGHT_VEHICLE)) == 0)
    }

    @Test("Atreides LIGHT_VEHICLE unlocks at campaign 1 (non-Harkonnen pin: availableCampaign=2 → gate passes at c≥1)")
    func atreidesLightVehicleMission2() {
        let built: UInt32 = (1 << REFINERY) | (1 << WINDTRAP)
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 1,
            playerHouseID: Simulation.House.atreides
        )
        #expect((mask & (1 << LIGHT_VEHICLE)) != 0)
    }

    @Test("Harkonnen LIGHT_VEHICLE unlocks at campaign 2 (original availableCampaign=3 → gate passes at c≥2)")
    func harkonnenLightVehicleMission3() {
        let built: UInt32 = (1 << REFINERY) | (1 << WINDTRAP)
        let notYet = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 1,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((notYet & (1 << LIGHT_VEHICLE)) == 0)
        let now = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.harkonnen,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 2,
            playerHouseID: Simulation.House.harkonnen
        )
        #expect((now & (1 << LIGHT_VEHICLE)) != 0)
    }

    @Test("ROCKET_TURRET upgrade gate: player needs upgradeLevel >= 2; AI skips")
    func rocketTurretUpgradeGate() {
        let built: UInt32 = (1 << OUTPOST) | (1 << WINDTRAP)
        // Player yard, upgradeLevel=1 → ROCKET_TURRET NOT in mask
        // (availableCampaign=0 actually fails unsigned-wrap gate, but put
        // campaign high to rule that out — the upgrade gate must hold).
        let playerLow = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 1,
            structuresBuilt: built,
            campaignID: 8,
            playerHouseID: Simulation.House.atreides
        )
        #expect((playerLow & (1 << ROCKET_TURRET)) == 0)
        // Same yard, upgradeLevel=2 → ROCKET_TURRET IS in mask.
        let playerHi = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 2,
            structuresBuilt: built,
            campaignID: 8,
            playerHouseID: Simulation.House.atreides
        )
        #expect((playerHi & (1 << ROCKET_TURRET)) != 0)
        // AI yard, upgradeLevel=0 → ROCKET_TURRET in mask (AI skips upgrade).
        let aiLow = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.ordos,
            yardUpgradeLevel: 0,
            structuresBuilt: built,
            campaignID: 8,
            playerHouseID: Simulation.House.atreides
        )
        #expect((aiLow & (1 << ROCKET_TURRET)) != 0)
    }

    @Test("ROCKET_TURRET campaign gate passes at c=0 (signed -1 threshold), so the prereq gate is what keeps it locked")
    func rocketTurretCampaignZeroSignedPromotion() {
        // availableCampaign=0 → signed threshold is -1 → campaign gate
        // always passes. OpenDUNE relies on C's int promotion of
        // `uint16 - 1`, NOT unsigned wrap. Verify by removing every
        // other gate in turn: RT unlocks when prereqs + upgrade + house
        // all match, regardless of how low the campaign is.
        let built: UInt32 = (1 << OUTPOST) | (1 << WINDTRAP)
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 2,
            structuresBuilt: built,
            campaignID: 0,
            playerHouseID: Simulation.House.atreides
        )
        #expect((mask & (1 << ROCKET_TURRET)) != 0)
        // But without prereqs, RT is still gated out.
        let maskNoPrereq = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 2,
            structuresBuilt: 0,
            campaignID: 0,
            playerHouseID: Simulation.House.atreides
        )
        #expect((maskNoPrereq & (1 << ROCKET_TURRET)) == 0)
    }

    @Test("CONSTRUCTION_YARD never buildable (availableCampaign=99 + FLAG_STRUCTURE_NEVER)")
    func constructionYardNeverBuildable() {
        // Even as AI (which skips prereqs), campaign gate at 99 still fails.
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 2,
            structuresBuilt: 0xFFFF_FFFF,
            campaignID: 8,
            playerHouseID: Simulation.House.harkonnen  // make yard AI to skip prereqs
        )
        #expect((mask & (1 << CONSTRUCTION_YARD)) == 0)
    }

    @Test("FLAG_STRUCTURE_NEVER: even when bit 31 of structuresBuilt is set, prereq gate still fails as a sanity check")
    func flagNeverPrereqSanity() {
        // If someone (buggy save) sets bit 31 of structuresBuilt, the
        // prereq check would match FLAG_STRUCTURE_NEVER. But the
        // availableCampaign=99 gate still protects us.
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: Simulation.House.atreides,
            yardUpgradeLevel: 0,
            structuresBuilt: 0xFFFF_FFFF,
            campaignID: 8,
            playerHouseID: Simulation.House.atreides
        )
        #expect((mask & (1 << CONSTRUCTION_YARD)) == 0)
    }
}
