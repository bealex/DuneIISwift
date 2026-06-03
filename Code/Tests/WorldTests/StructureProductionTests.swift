import DuneIIContracts
import Testing

@testable import DuneIIWorld

/// `structureTickStructure` — the `tickStructure` body of `GameLoop_Structure` (`structure.c:53`): the
/// build/repair economy run on the structure cursor. Decision-trace coverage of the deterministic branches:
/// structure self-repair, factory production progress + completion, the out-of-money hold, and the repair
/// pad's unit-repair countdown. Expected credit/HP/countdown deltas are derived from the (golden-verified)
/// stat tables so the tests track the tables, not hand-copied numbers.
@Suite("Structure production + repair (tickStructure)")
struct StructureProductionTests {
    private func place(
        _ s: inout GameState,
        _ type: StructureType,
        house: UInt8 = 0,
        hp: UInt16? = nil,
        state: StructureState = .idle
    ) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = hp ?? StructureInfo[type].o.hitpoints
        s.structures[slot].state = state
        return slot
    }

    // MARK: - Structure self-repair (the `.repairing` branch)

    @Test("a repairing structure heals 5 HP and is billed the 1.07 repair cost")
    func repairHeals() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let full = StructureInfo[.windtrap].o.hitpoints
        let slot = place(&s, .windtrap, hp: full - 20)
        s.structures[slot].o.flags.insert(.repairing)
        s.houses[0].credits = 1000

        let cost = UInt16((2 * 256 / UInt32(full) * UInt32(StructureInfo[.windtrap].o.buildCredits) + 128) / 256)
        s.structureTickStructure(slot)
        #expect(s.structures[slot].o.hitpoints == full - 15)  // +5 (player)
        #expect(s.houses[0].credits == 1000 - cost)
        #expect(s.structures[slot].o.flags.contains(.repairing))  // not done yet
    }

    @Test("repair clamps at full HP and clears the repairing/onHold flags")
    func repairFinishes() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let full = StructureInfo[.windtrap].o.hitpoints
        let slot = place(&s, .windtrap, hp: full - 2)  // +5 overshoots → clamps
        s.structures[slot].o.flags.insert(.repairing)
        s.structures[slot].o.flags.insert(.onHold)
        s.houses[0].credits = 1000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].o.hitpoints == full)
        #expect(!s.structures[slot].o.flags.contains(.repairing))
        #expect(!s.structures[slot].o.flags.contains(.onHold))
    }

    @Test("repair with no money cancels the repair and heals nothing")
    func repairBroke() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let full = StructureInfo[.windtrap].o.hitpoints
        let slot = place(&s, .windtrap, hp: full - 20)
        s.structures[slot].o.flags.insert(.repairing)
        s.houses[0].credits = 0

        s.structureTickStructure(slot)
        #expect(s.structures[slot].o.hitpoints == full - 20)
        #expect(!s.structures[slot].o.flags.contains(.repairing))
    }

    // MARK: - Factory production (the `else` branch)

    /// A Light Factory at full HP building a Trike: buildSpeed 256, countDown drops by 256, credits drop by
    /// `buildCost/256` where `buildCost = trike.buildCredits * 256 / trike.buildTime`.
    @Test("a busy factory advances its build by buildSpeed and is billed buildCost")
    func factoryProgresses() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let slot = place(&s, .lightVehicle, state: .busy)
        s.structures[slot].o.linkedID = 0  // something is queued (≠ 0xFF)
        s.structures[slot].objectType = UInt16(UnitType.trike.rawValue)
        s.structures[slot].countDown = 1000
        s.houses[0].credits = 5000

        let buildCost = UInt32(UnitInfo[.trike].o.buildCredits) * 256 / UInt32(UnitInfo[.trike].o.buildTime)
        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 1000 - 256)
        #expect(s.houses[0].credits == UInt16(5000 - buildCost / 256))
        #expect(s.structures[slot].buildCostRemainder == UInt16(buildCost & 0xFF))
        #expect(s.structures[slot].state == .busy)
    }

    @Test("a build that reaches 0 completes to READY and clears the cost remainder")
    func factoryCompletes() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let slot = place(&s, .lightVehicle, state: .busy)
        s.structures[slot].o.linkedID = 0
        s.structures[slot].objectType = UInt16(UnitType.trike.rawValue)
        s.structures[slot].countDown = 100  // < buildSpeed (256) → finishes this tick
        s.structures[slot].buildCostRemainder = 200
        s.houses[0].credits = 5000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 0)
        #expect(s.structures[slot].buildCostRemainder == 0)
        #expect(s.structures[slot].state == .ready)
    }

    @Test("a player factory out of money goes on hold")
    func factoryOnHold() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        s.playerHouseID = 0
        let slot = place(&s, .lightVehicle, state: .busy)
        s.structures[slot].o.linkedID = 0
        s.structures[slot].objectType = UInt16(UnitType.trike.rawValue)
        s.structures[slot].countDown = 1000
        s.houses[0].credits = 0

        s.structureTickStructure(slot)
        #expect(s.structures[slot].o.flags.contains(.onHold))
        #expect(s.structures[slot].countDown == 1000)  // no progress
    }

    // MARK: - Player pause / resume (widget_click.c STR_D_DONE / STR_ON_HOLD)

    @Test("pausing an in-progress build sets onHold and stops it advancing; resume continues it")
    func pauseThenResume() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        s.playerHouseID = 0
        let slot = place(&s, .lightVehicle, state: .busy)
        s.structures[slot].o.linkedID = 0
        s.structures[slot].objectType = UInt16(UnitType.trike.rawValue)
        s.structures[slot].countDown = 1000
        s.houses[0].credits = 5000

        // Pause (the player clicking "%d%% DONE"): onHold set, and the next tick makes no progress.
        let wasBuilding = s.structurePauseBuild(slot)
        #expect(wasBuilding)
        #expect(s.structures[slot].o.flags.contains(.onHold))
        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 1000)  // held → no progress, no billing
        #expect(s.houses[0].credits == 5000)

        // Resume (clicking "ON HOLD"): the hold clears and the build advances again.
        let wasHeld = s.structureResumeBuild(slot)
        #expect(wasHeld)
        #expect(!s.structures[slot].o.flags.contains(.onHold))
        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 1000 - 256)
        #expect(s.houses[0].credits < 5000)
    }

    @Test("resuming a build held for lack of money does nothing until credits return")
    func resumeStillBrokeReholds() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        s.playerHouseID = 0
        let slot = place(&s, .lightVehicle, state: .busy)
        s.structures[slot].o.linkedID = 0
        s.structures[slot].objectType = UInt16(UnitType.trike.rawValue)
        s.structures[slot].countDown = 1000
        s.houses[0].credits = 0
        s.structureTickStructure(slot)  // out of money → on hold
        #expect(s.structures[slot].o.flags.contains(.onHold))

        // Resume while still broke: the hold clears, but the very next tick re-holds it (no money).
        s.structureResumeBuild(slot)
        s.structureTickStructure(slot)
        #expect(s.structures[slot].o.flags.contains(.onHold))
        #expect(s.structures[slot].countDown == 1000)  // still no progress

        // Credits arrive, resume again → it advances.
        s.houses[0].credits = 5000
        s.structureResumeBuild(slot)
        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 1000 - 256)
    }

    @Test("an idle (not BUSY) factory does nothing")
    func factoryIdleNoop() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let slot = place(&s, .lightVehicle, state: .idle)  // not BUSY → the guard fails
        s.structures[slot].o.linkedID = 0
        s.structures[slot].objectType = UInt16(UnitType.trike.rawValue)
        s.structures[slot].countDown = 1000
        s.houses[0].credits = 5000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 1000)
        #expect(s.houses[0].credits == 5000)
    }

    // MARK: - Repair pad unit-repair countdown (the `STRUCTURE_REPAIR` block)

    @Test("a repair pad advances its linked unit's repair countdown and bills 2*buildCredits/256")
    func repairPadProgresses() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        let unit = s.unitAllocate(index: 0xFFFF, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        let slot = place(&s, .repair, state: .busy)
        s.structures[slot].o.linkedID = UInt8(unit)
        s.structures[slot].countDown = 1000
        s.houses[0].credits = 5000

        let cost = UInt16(2 * UInt32(UnitInfo[.tank].o.buildCredits) / 256)
        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 1000 - 256)
        #expect(s.houses[0].credits == 5000 - cost)
    }

    @Test("a repair pad finishing its countdown goes READY")
    func repairPadCompletes() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        let unit = s.unitAllocate(index: 0xFFFF, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        let slot = place(&s, .repair, state: .busy)
        s.structures[slot].o.linkedID = UInt8(unit)
        s.structures[slot].countDown = 100  // < repairSpeed → finishes
        s.houses[0].credits = 5000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].countDown == 0)
        #expect(s.structures[slot].state == .ready)
    }

    @Test("an idle repair pad with money auto-resumes from hold")
    func repairPadAutoResume() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let slot = place(&s, .repair, state: .idle)
        s.structures[slot].o.linkedID = 0xFF  // nothing linked
        s.structures[slot].o.flags.insert(.onHold)
        s.houses[0].credits = 100

        s.structureTickStructure(slot)
        #expect(!s.structures[slot].o.flags.contains(.onHold))
    }

    // MARK: - Upgrade branch (the `.upgrading` flag)

    @Test("an upgrading structure pays 1/40 build cost per tick and steps upgradeTimeLeft by 5")
    func upgradeProgresses() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let slot = place(&s, .barracks)
        s.structures[slot].o.flags.insert(.upgrading)
        s.structures[slot].upgradeTimeLeft = 100
        s.houses[0].credits = 1000

        let cost = StructureInfo[.barracks].o.buildCredits / 40
        s.structureTickStructure(slot)
        #expect(s.structures[slot].upgradeTimeLeft == 95)
        #expect(s.houses[0].credits == 1000 - cost)
        #expect(s.structures[slot].o.flags.contains(.upgrading))
    }

    @Test("a finished upgrade bumps the level, clears upgrading, and re-arms when another upgrade remains")
    func upgradeCompletesAndRearms() {
        var s = GameState(); _ = s.houseAllocate(index: 1)
        s.campaignID = 5  // Heavy Vehicle: upgradeCampaign [4,5,6]
        let slot = place(&s, .heavyVehicle, house: 1)
        s.structures[slot].o.flags.insert(.upgrading)
        s.structures[slot].upgradeTimeLeft = 5  // ≤ 5 → finishes this tick
        s.houses[1].credits = 1000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].upgradeLevel == 1)
        #expect(!s.structures[slot].o.flags.contains(.upgrading))
        #expect(s.structures[slot].upgradeTimeLeft == 100)  // level-1 upgrade (campaign 5 ≥ 5) still available
    }

    @Test("a finished final upgrade re-arms to 0 (nothing more to upgrade)")
    func upgradeCompletesTerminal() {
        var s = GameState(); _ = s.houseAllocate(index: 0)  // Barracks: upgradeCampaign [2,0,0]
        let slot = place(&s, .barracks)
        s.structures[slot].o.flags.insert(.upgrading)
        s.structures[slot].upgradeTimeLeft = 3
        s.houses[0].credits = 1000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].upgradeLevel == 1)
        #expect(s.structures[slot].upgradeTimeLeft == 0)  // upgradeCampaign[1] == 0 → not upgradable
    }

    @Test("the Ordos Heavy Vehicle gets its last upgrade free (level jumps 1 → 3)")
    func upgradeOrdosHeavyVehicleFree() {
        var s = GameState(); _ = s.houseAllocate(index: 2)  // Ordos
        s.campaignID = 9
        let slot = place(&s, .heavyVehicle, house: 2)
        s.structures[slot].upgradeLevel = 1
        s.structures[slot].o.flags.insert(.upgrading)
        s.structures[slot].upgradeTimeLeft = 5
        s.houses[2].credits = 1000

        s.structureTickStructure(slot)
        #expect(s.structures[slot].upgradeLevel == 3)  // 2 → 3 (free last upgrade)
    }

    @Test("an upgrade with no money is cancelled")
    func upgradeBroke() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        let slot = place(&s, .barracks)
        s.structures[slot].o.flags.insert(.upgrading)
        s.structures[slot].upgradeTimeLeft = 100
        s.houses[0].credits = 0

        s.structureTickStructure(slot)
        #expect(!s.structures[slot].o.flags.contains(.upgrading))
        #expect(s.structures[slot].upgradeTimeLeft == 100)  // unchanged
    }

    // MARK: - Structure_IsUpgradable

    @Test("upgradability tracks the per-house/type rules and the campaign gate")
    func isUpgradable() {
        var s = GameState(); _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 2)

        // Barracks (upgradeCampaign[0] == 2) is upgradable from campaign 1; Light Factory (3) is not yet.
        let barracks = place(&s, .barracks)
        #expect(s.structureIsUpgradable(barracks))
        let light = place(&s, .lightVehicle)
        #expect(!s.structureIsUpgradable(light))  // 3 > campaignID(1)+1

        // Harkonnen Hi-Tech is never upgradable.
        s.campaignID = 9
        let hitech = place(&s, .highTech, house: 0)
        #expect(!s.structureIsUpgradable(hitech))
    }

    @Test("the construction yard's 2nd upgrade requires the rocket turret's prerequisites")
    func isUpgradableConstructionYard() {
        var s = GameState(); _ = s.houseAllocate(index: 0)
        s.campaignID = 5  // CY upgradeCampaign [4,6,0]; level-1 needs 6 ≤ 6
        let cy = place(&s, .constructionYard)
        s.structures[cy].upgradeLevel = 1

        #expect(!s.structureIsUpgradable(cy))  // no prerequisite structures built
        s.houses[0].structuresBuilt = StructureInfo[.rocketTurret].o.structuresRequired
        #expect(s.structureIsUpgradable(cy))
    }
}
