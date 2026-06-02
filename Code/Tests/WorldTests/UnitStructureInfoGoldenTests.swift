import Foundation
import Testing
import DuneIIContracts
@testable import DuneIIWorld

/// Field-for-field parity of the big `g_table_unitInfo` / `g_table_structureInfo` tables against the
/// OpenDUNE golden dumps, plus a handful of hand-known spot-checks as an independent anchor (the table
/// literals are generated from these same fixtures, so the spot-checks guard against a dumper bug).
@Suite("UnitInfo / StructureInfo golden parity")
struct UnitStructureInfoGoldenTests {
    struct ObjFlags: Decodable {
        let hasShadow, factory, notOnConcrete, busyStateIsIncoming, blurTile, hasTurret: Int
        let conquerable, canBePickedUp, noMessageOnDeath, tabSelectable, scriptNoSlowdown: Int
        let targetAir, priority: Int
    }

    struct UnitFlags: Decodable {
        let isBullet, explodeOnDeath, sonicProtection, canWobble, isTracked, isGroundUnit: Int
        let mustStayInMap, firesTwice, impactOnSand, isNotDeviatable, hasAnimationSet: Int
        let notAccurate, isNormalUnit: Int
    }

    struct UnitRow: Decodable {
        let index: Int
        let stringID_abbrev: UInt16
        let name: String
        let stringID_full: UInt16
        let wsa: String?
        let objectFlags: ObjFlags
        let spawnChance, hitpoints, fogUncoverRadius, spriteID, buildCredits, buildTime: UInt16
        let availableCampaign: UInt16
        let structuresRequired: UInt32
        let sortPriority, upgradeLevelRequired: UInt8
        let actionsPlayer: [Int]
        let available: Int
        let hintStringID, priorityBuild, priorityTarget: UInt16
        let availableHouse: UInt8
        let indexStart, indexEnd: UInt16
        let unitFlags: UnitFlags
        let dimension, movementType, animationSpeed, movingSpeedFactor: UInt16
        let turningSpeed: UInt8
        let groundSpriteID, turretSpriteID, actionAI: UInt16
        let displayMode: Int
        let destroyedSpriteID, fireDelay, fireDistance, damage, explosionType: UInt16
        let bulletType: UInt8
        let bulletSound: UInt16
    }

    struct StructureRow: Decodable {
        let index: Int
        let stringID_abbrev: UInt16
        let name: String
        let stringID_full: UInt16
        let wsa: String?
        let objectFlags: ObjFlags
        let spawnChance, hitpoints, fogUncoverRadius, spriteID, buildCredits, buildTime: UInt16
        let availableCampaign: UInt16
        let structuresRequired: UInt32
        let sortPriority, upgradeLevelRequired: UInt8
        let actionsPlayer: [Int]
        let available: Int
        let hintStringID, priorityBuild, priorityTarget: UInt16
        let availableHouse: UInt8
        let enterFilter: UInt32
        let creditsStorage: UInt16
        let powerUsage: Int16
        let layout: Int
        let iconGroup: UInt16
        let animationIndex: [UInt8]
        let buildableUnits: [UInt8]
        let upgradeCampaign: [UInt16]
    }

    /// Assert the embedded `ObjectInfo` matches the dumped common fields.
    private func checkObject(_ o: ObjectInfo, _ r: ObjectRow) {
        #expect(o.stringIDAbbrev == r.stringID_abbrev)
        #expect(o.name == r.name)
        #expect(o.stringIDFull == r.stringID_full)
        #expect(o.wsa == r.wsa)
        let f = o.flags
        #expect(f.contains(.hasShadow) == (r.objectFlags.hasShadow != 0))
        #expect(f.contains(.factory) == (r.objectFlags.factory != 0))
        #expect(f.contains(.notOnConcrete) == (r.objectFlags.notOnConcrete != 0))
        #expect(f.contains(.busyStateIsIncoming) == (r.objectFlags.busyStateIsIncoming != 0))
        #expect(f.contains(.blurTile) == (r.objectFlags.blurTile != 0))
        #expect(f.contains(.hasTurret) == (r.objectFlags.hasTurret != 0))
        #expect(f.contains(.conquerable) == (r.objectFlags.conquerable != 0))
        #expect(f.contains(.canBePickedUp) == (r.objectFlags.canBePickedUp != 0))
        #expect(f.contains(.noMessageOnDeath) == (r.objectFlags.noMessageOnDeath != 0))
        #expect(f.contains(.tabSelectable) == (r.objectFlags.tabSelectable != 0))
        #expect(f.contains(.scriptNoSlowdown) == (r.objectFlags.scriptNoSlowdown != 0))
        #expect(f.contains(.targetAir) == (r.objectFlags.targetAir != 0))
        #expect(f.contains(.priority) == (r.objectFlags.priority != 0))
        #expect(o.spawnChance == r.spawnChance)
        #expect(o.hitpoints == r.hitpoints)
        #expect(o.fogUncoverRadius == r.fogUncoverRadius)
        #expect(o.spriteID == r.spriteID)
        #expect(o.buildCredits == r.buildCredits)
        #expect(o.buildTime == r.buildTime)
        #expect(o.availableCampaign == r.availableCampaign)
        #expect(o.structuresRequired == r.structuresRequired)
        #expect(o.sortPriority == r.sortPriority)
        #expect(o.upgradeLevelRequired == r.upgradeLevelRequired)
        #expect(o.actionsPlayer.all.map { $0.rawValue } == r.actionsPlayer)
        #expect(Int(o.available) == r.available)
        #expect(o.hintStringID == r.hintStringID)
        #expect(o.priorityBuild == r.priorityBuild)
        #expect(o.priorityTarget == r.priorityTarget)
        #expect(o.availableHouse == r.availableHouse)
    }

    /// Common fields shared by both rows, extracted so `checkObject` can take either.
    struct ObjectRow {
        let stringID_abbrev: UInt16, name: String, stringID_full: UInt16, wsa: String?
        let objectFlags: ObjFlags
        let spawnChance, hitpoints, fogUncoverRadius, spriteID, buildCredits, buildTime: UInt16
        let availableCampaign: UInt16, structuresRequired: UInt32
        let sortPriority, upgradeLevelRequired: UInt8
        let actionsPlayer: [Int], available: Int
        let hintStringID, priorityBuild, priorityTarget: UInt16, availableHouse: UInt8
    }

    @Test("g_table_unitInfo matches for every unit type")
    func units() throws {
        let rows = GoldenFixture.decode("unitinfo-golden.jsonl", as: UnitRow.self)
        #expect(rows.count == UnitType.allCases.count)
        for r in rows {
            let type = try #require(UnitType(rawValue: r.index))
            let u = UnitInfo[type]
            checkObject(u.o, ObjectRow(
                stringID_abbrev: r.stringID_abbrev, name: r.name, stringID_full: r.stringID_full,
                wsa: r.wsa, objectFlags: r.objectFlags, spawnChance: r.spawnChance,
                hitpoints: r.hitpoints, fogUncoverRadius: r.fogUncoverRadius, spriteID: r.spriteID,
                buildCredits: r.buildCredits, buildTime: r.buildTime,
                availableCampaign: r.availableCampaign, structuresRequired: r.structuresRequired,
                sortPriority: r.sortPriority, upgradeLevelRequired: r.upgradeLevelRequired,
                actionsPlayer: r.actionsPlayer, available: r.available, hintStringID: r.hintStringID,
                priorityBuild: r.priorityBuild, priorityTarget: r.priorityTarget,
                availableHouse: r.availableHouse))
            #expect(u.indexStart == r.indexStart)
            #expect(u.indexEnd == r.indexEnd)
            let f = u.flags
            #expect(f.contains(.isBullet) == (r.unitFlags.isBullet != 0))
            #expect(f.contains(.explodeOnDeath) == (r.unitFlags.explodeOnDeath != 0))
            #expect(f.contains(.sonicProtection) == (r.unitFlags.sonicProtection != 0))
            #expect(f.contains(.canWobble) == (r.unitFlags.canWobble != 0))
            #expect(f.contains(.isTracked) == (r.unitFlags.isTracked != 0))
            #expect(f.contains(.isGroundUnit) == (r.unitFlags.isGroundUnit != 0))
            #expect(f.contains(.mustStayInMap) == (r.unitFlags.mustStayInMap != 0))
            #expect(f.contains(.firesTwice) == (r.unitFlags.firesTwice != 0))
            #expect(f.contains(.impactOnSand) == (r.unitFlags.impactOnSand != 0))
            #expect(f.contains(.isNotDeviatable) == (r.unitFlags.isNotDeviatable != 0))
            #expect(f.contains(.hasAnimationSet) == (r.unitFlags.hasAnimationSet != 0))
            #expect(f.contains(.notAccurate) == (r.unitFlags.notAccurate != 0))
            #expect(f.contains(.isNormalUnit) == (r.unitFlags.isNormalUnit != 0))
            #expect(u.dimension == r.dimension)
            #expect(u.movementType.rawValue == Int(r.movementType))
            #expect(u.animationSpeed == r.animationSpeed)
            #expect(u.movingSpeedFactor == r.movingSpeedFactor)
            #expect(u.turningSpeed == r.turningSpeed)
            #expect(u.groundSpriteID == r.groundSpriteID)
            #expect(u.turretSpriteID == r.turretSpriteID)
            #expect(u.actionAI == r.actionAI)
            #expect(u.displayMode.rawValue == r.displayMode)
            #expect(u.destroyedSpriteID == r.destroyedSpriteID)
            #expect(u.fireDelay == r.fireDelay)
            #expect(u.fireDistance == r.fireDistance)
            #expect(u.damage == r.damage)
            #expect(u.explosionType == r.explosionType)
            #expect(u.bulletType == r.bulletType)
            #expect(u.bulletSound == r.bulletSound)
        }
    }

    @Test("g_table_structureInfo matches for every structure type")
    func structures() throws {
        let rows = GoldenFixture.decode("structureinfo-golden.jsonl", as: StructureRow.self)
        #expect(rows.count == StructureType.allCases.count)
        for r in rows {
            let type = try #require(StructureType(rawValue: r.index))
            let s = StructureInfo[type]
            checkObject(s.o, ObjectRow(
                stringID_abbrev: r.stringID_abbrev, name: r.name, stringID_full: r.stringID_full,
                wsa: r.wsa, objectFlags: r.objectFlags, spawnChance: r.spawnChance,
                hitpoints: r.hitpoints, fogUncoverRadius: r.fogUncoverRadius, spriteID: r.spriteID,
                buildCredits: r.buildCredits, buildTime: r.buildTime,
                availableCampaign: r.availableCampaign, structuresRequired: r.structuresRequired,
                sortPriority: r.sortPriority, upgradeLevelRequired: r.upgradeLevelRequired,
                actionsPlayer: r.actionsPlayer, available: r.available, hintStringID: r.hintStringID,
                priorityBuild: r.priorityBuild, priorityTarget: r.priorityTarget,
                availableHouse: r.availableHouse))
            #expect(s.enterFilter == r.enterFilter)
            #expect(s.creditsStorage == r.creditsStorage)
            #expect(s.powerUsage == r.powerUsage)
            #expect(s.layout.rawValue == r.layout)
            #expect(s.iconGroup == r.iconGroup)
            #expect(s.animationIndex == r.animationIndex)
            #expect(s.buildableUnits == r.buildableUnits)
            #expect(s.upgradeCampaign == r.upgradeCampaign)
        }
    }

    /// Independent hand-known anchors (would catch a dumper/generator bug that the generated table
    /// alone cannot, since both sides derive from the same dump).
    @Test("hand-known unit/structure values")
    func spotChecks() {
        #expect(UnitInfo[.carryall].o.hitpoints == 100)
        #expect(UnitInfo[.carryall].o.buildCredits == 800)
        #expect(UnitInfo[.carryall].movementType == .winger)
        #expect(UnitInfo[.devastator].o.hitpoints == 400)
        #expect(UnitInfo[.devastator].flags.contains(.explodeOnDeath))
        #expect(UnitInfo[.harvester].movementType == .harvester)
        #expect(UnitInfo[.sandworm].o.hitpoints == 1000)
        #expect(UnitInfo[.sonicTank].flags.contains(.sonicProtection))
        #expect(UnitInfo[.tank].o.flags.contains(.hasTurret))
        #expect(UnitInfo[.missileRocket].o.wsa == nil)

        #expect(StructureInfo[.windtrap].powerUsage == -100)
        #expect(StructureInfo[.constructionYard].o.structuresRequired == 0xFFFFFFFF)
        #expect(StructureInfo[.palace].layout == .layout3x3)
        #expect(StructureInfo[.refinery].enterFilter == (1 << UInt32(UnitType.harvester.rawValue)))
        #expect(StructureInfo[.barracks].o.flags.contains(.factory))
        #expect(StructureInfo[.silo].creditsStorage == 1000)
    }
}
