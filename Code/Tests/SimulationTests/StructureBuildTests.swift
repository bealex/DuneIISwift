import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// The build-GUI query + command seam: `Structure_GetBuildable` (`buildables`), the build-progress read
/// (`buildState`), and the construction-yard place flow (`structurePlaceReady`) + the `Command` cases.
/// See `Documentation/Architecture/BuildGUI.md`.
@Suite("Structure build GUI seam")
struct StructureBuildTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func sim() -> Simulation {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        s.houses[0].structuresBuilt = 0xFFFFFF; s.houses[0].credits = 5000
        s.campaignID = 9
        return Simulation(state: s, scriptInfo: info)
    }

    private func addFactory(_ s: inout GameState, _ type: StructureType, house: UInt8 = 0) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
        s.structures[slot].hitpointsMax = StructureInfo[type].o.hitpoints
        s.structures[slot].state = .idle
        s.structures[slot].objectType = 0xFFFF
        s.structures[slot].o.linkedID = 0xFF
        return slot
    }

    @Test("a light factory's buildables list its units (the Harkonnen quad), with the right cost")
    func buildablesUnits() {
        var simulation = self.sim()
        // House 0 = Harkonnen: a light factory builds the quad (the trike is Atreides/Ordos-only). A
        // Harkonnen light factory starts at upgradeLevel 1 (Structure_Create), which the quad requires.
        let fac = addFactory(&simulation.state, .lightVehicle)
        simulation.state.structures[fac].upgradeLevel = 1
        let items = simulation.buildables(forStructure: fac)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.isStructure })
        let quad = items.first { $0.objectType == UInt16(UnitType.quad.rawValue) }
        #expect(quad != nil)
        #expect(quad?.cost == Int(UnitInfo[.quad].o.buildCredits))
    }

    @Test("a construction yard's buildables list structures (windtrap), as structures")
    func buildablesStructures() {
        var simulation = self.sim()
        let cy = addFactory(&simulation.state, .constructionYard)
        let items = simulation.buildables(forStructure: cy)
        let windtrap = items.first { $0.objectType == UInt16(StructureType.windtrap.rawValue) }
        #expect(windtrap != nil)
        #expect(windtrap?.isStructure == true)
        #expect(items.allSatisfy { $0.isStructure })
    }

    @Test("a non-factory has no buildables")
    func buildablesNonFactory() {
        var simulation = self.sim()
        let wt = addFactory(&simulation.state, .windtrap)
        #expect(simulation.buildables(forStructure: wt).isEmpty)
    }

    // MARK: - buildOptions (the full greyed-out menu)

    /// The available subset of `buildOptions` must equal `buildables` (the cross-engine-verified
    /// `Structure_GetBuildable` port) — the GUI's "show all, grey the locked" list can never disagree with
    /// what is actually buildable. Checked for both factory kinds.
    @Test("buildOptions' available subset equals buildables (construction yard + unit factory)")
    func buildOptionsAvailableMatchesBuildables() {
        var simulation = self.sim()
        let cy = addFactory(&simulation.state, .constructionYard)
        let cyAvail = simulation.buildOptions(forStructure: cy).filter(\.isAvailable).map(\.item)
        #expect(cyAvail == simulation.buildables(forStructure: cy))
        #expect(!cyAvail.isEmpty)

        let fac = addFactory(&simulation.state, .lightVehicle)
        simulation.state.structures[fac].upgradeLevel = 1
        let facAvail = simulation.buildOptions(forStructure: fac).filter(\.isAvailable).map(\.item)
        #expect(facAvail == simulation.buildables(forStructure: fac))
        #expect(!facAvail.isEmpty)
        // The construction yard self-entry is never a build option.
        #expect(!simulation.buildOptions(forStructure: cy).contains { $0.item.objectType == UInt16(StructureType.constructionYard.rawValue) })
    }

    /// With every Heavy-Factory prerequisite built but the campaign too low, the Heavy Factory is listed but
    /// locked by a single `.campaign` blocker; raising the campaign level unlocks it. (This is the "can't
    /// build Heavy Factory" case — the gate is `campaignID >= availableCampaign - 1`, Heavy `availableCampaign`
    /// 4 ⇒ needs `campaignID >= 3`.)
    @Test("Heavy Factory is campaign-locked at a low level, then unlocks")
    func heavyFactoryCampaignGate() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].structuresBuilt =
            (1 << StructureType.windtrap.rawValue) | (1 << StructureType.outpost.rawValue) | (1 << StructureType.lightVehicle.rawValue)
        s.campaignID = 1
        let cy = addFactory(&s, .constructionYard)
        var sm = Simulation(state: s, scriptInfo: info)
        let heavy = UInt16(StructureType.heavyVehicle.rawValue)
        let locked = sm.buildOptions(forStructure: cy).first { $0.item.objectType == heavy }
        #expect(locked?.isAvailable == false)
        #expect(locked?.blockers == [.campaign(level: 3)])
        // Raising the campaign level removes the only blocker.
        sm.state.campaignID = 3
        let unlocked = sm.buildOptions(forStructure: cy).first { $0.item.objectType == heavy }
        #expect(unlocked?.isAvailable == true)
    }

    /// `isCampaignGated` tags the items the GUI hides (any `.campaign` blocker present); a purely
    /// prerequisite-locked item is not gated, so it stays visible (greyed). This is the filter the client
    /// applies to `buildOptions`.
    @Test("isCampaignGated flags campaign-locked items but not prerequisite-locked ones")
    func isCampaignGatedTagsCampaignLocks() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        // Heavy Factory's prerequisites are all built, so its only block is the low campaign level → gated.
        s.houses[0].structuresBuilt =
            (1 << StructureType.windtrap.rawValue) | (1 << StructureType.outpost.rawValue) | (1 << StructureType.lightVehicle.rawValue)
        s.campaignID = 1
        let cy = addFactory(&s, .constructionYard)
        let sm = Simulation(state: s, scriptInfo: info)
        let options = sm.buildOptions(forStructure: cy)
        let heavy = options.first { $0.item.objectType == UInt16(StructureType.heavyVehicle.rawValue) }
        #expect(heavy?.isCampaignGated == true)
        // The windtrap is available from campaign 1 with no prerequisites → not gated.
        let windtrap = options.first { $0.item.objectType == UInt16(StructureType.windtrap.rawValue) }
        #expect(windtrap?.isCampaignGated == false)
        // The client filter (drop campaign-gated rows) removes Heavy Factory but keeps available items.
        let shown = options.filter { !$0.isCampaignGated }
        #expect(!shown.contains { $0.item.objectType == UInt16(StructureType.heavyVehicle.rawValue) })
        #expect(shown.contains { $0.isAvailable })
    }

    /// A locked item enumerates its missing prerequisite structures (in bit order), with no campaign blocker
    /// when the campaign is high enough.
    @Test("a locked construction-yard item lists its missing prerequisite structures")
    func missingPrerequisiteBlockers() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].structuresBuilt = 0   // nothing built yet
        s.campaignID = 9                  // high enough that only structures are missing
        let cy = addFactory(&s, .constructionYard)
        var sm = Simulation(state: s, scriptInfo: info)
        let heavy = sm.buildOptions(forStructure: cy).first { $0.item.objectType == UInt16(StructureType.heavyVehicle.rawValue) }
        #expect(heavy?.isAvailable == false)
        #expect(heavy?.blockers == [.structure(.lightVehicle), .structure(.windtrap), .structure(.outpost)])
    }

    /// `armPlacedFactoryUpgrades` (the client's post-load fixup that the hand-rolled scenario loader skips):
    /// a **player** factory gets `upgradeTimeLeft = 100` so the GUI offers Upgrade; an **AI** factory is taken
    /// straight to its max upgrade level with `upgradeTimeLeft = 0`. (A CY's first upgrade unlocks at
    /// `campaignID >= 3`, so campaign 5 here.)
    @Test("armPlacedFactoryUpgrades arms a player CY and maxes an AI CY")
    func armsPlacedFactoryUpgrades() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 1)
        s.campaignID = 5
        let playerCY = addFactory(&s, .constructionYard, house: 0)
        let aiCY = addFactory(&s, .constructionYard, house: 1)
        // Loader-style init leaves the upgrade unarmed (no Upgrade option) — the bug this fixes.
        #expect(s.structures[playerCY].upgradeTimeLeft == 0)
        s.armPlacedFactoryUpgrades()
        // Player CY: armed for the GUI, level unchanged (the player upgrades manually).
        #expect(s.structures[playerCY].upgradeTimeLeft == 100)
        #expect(s.structures[playerCY].upgradeLevel == 0)
        // AI CY: jumped straight to its max reachable level (≥1), no GUI arm.
        #expect(s.structures[aiCY].upgradeLevel >= 1)
        #expect(s.structures[aiCY].upgradeTimeLeft == 0)
    }

    @Test("buildState reports progress and readiness across a build")
    func buildStateProgress() {
        var simulation = self.sim()
        let fac = addFactory(&simulation.state, .lightVehicle)
        #expect(simulation.buildState(structureSlot: fac) == nil)   // idle ⇒ nothing
        let combat = simulation.unitScript!.combat
        _ = combat.structureBuildObject(slot: fac, objectType: UInt16(UnitType.trike.rawValue), in: &simulation.state)
        let started = simulation.buildState(structureSlot: fac)
        #expect(started?.displayName == UnitType.trike.displayName)
        #expect(started?.isReady == false)
        #expect((started?.progress ?? 1) < 0.01)                    // just started
        // Force completion.
        simulation.state.structures[fac].countDown = 0
        simulation.state.structures[fac].state = .ready
        let done = simulation.buildState(structureSlot: fac)
        #expect(done?.isReady == true)
        #expect((done?.progress ?? 0) > 0.99)
    }

    @Test("structurePlaceReady places the ready CY structure and resets the factory")
    func placeReady() {
        var simulation = self.sim()
        simulation.state.validateStrictIfZero = 1   // bypass terrain/concrete checks for a synthetic map
        let cy = addFactory(&simulation.state, .constructionYard)
        let combat = simulation.unitScript!.combat
        #expect(combat.structureBuildObject(slot: cy, objectType: UInt16(StructureType.windtrap.rawValue), in: &simulation.state))
        let product = Int(simulation.state.structures[cy].o.linkedID)
        simulation.state.structures[cy].countDown = 0
        simulation.state.structures[cy].state = .ready

        let tile = Tile32.packXY(x: 20, y: 20)
        #expect(combat.structurePlaceReady(factory: cy, position: tile, in: &simulation.state))
        // Product is on the map; factory reset to idle and unlinked.
        #expect(!simulation.state.structures[product].o.flags.contains(.isNotOnMap))
        #expect(simulation.state.structures[cy].o.linkedID == 0xFF)
        #expect(simulation.state.structures[cy].state == .idle)
        #expect(simulation.state.structures[cy].objectType == 0xFFFF)
    }

    @Test("a player-placed structure is seen by all houses (stock) but only the player with aiFogOfWar on")
    func placedStructureVisibility() {
        for fog in [false, true] {
            var simulation = self.sim()                 // playerHouseID = 0
            simulation.state.validateStrictIfZero = 1
            simulation.state.aiFogOfWar = fog
            let cy = addFactory(&simulation.state, .constructionYard)
            let combat = simulation.unitScript!.combat
            #expect(combat.structureBuildObject(slot: cy, objectType: UInt16(StructureType.windtrap.rawValue), in: &simulation.state))
            let product = Int(simulation.state.structures[cy].o.linkedID)
            simulation.state.structures[cy].countDown = 0
            simulation.state.structures[cy].state = .ready
            #expect(combat.structurePlaceReady(factory: cy, position: Tile32.packXY(x: 20, y: 20), in: &simulation.state))

            let seen = simulation.state.structures[product].o.seenByHouses
            if fog { #expect(seen == UInt8(1 << 0)) }    // only the player (house 0)
            else { #expect(seen == 0xFF) }               // stock 1.07: seen by all houses
        }
    }

    @Test("each placed refinery spawns its own harvester (a 2nd refinery ⇒ a 2nd harvester)")
    func refineryHarvesterPerPlacement() throws {
        var s = GameState(random256Seed: 0x55, randomLCGSeed: 0x55)
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        s.houses[0].structuresBuilt = 0xFFFFFF; s.houses[0].credits = 5000; s.campaignID = 9
        let combat = UnitCombat(movement: UnitMovement(scriptInfo: info))

        func placeRefinery(at corner: UInt16) {
            let cy = addFactory(&s, .constructionYard)
            #expect(combat.structureBuildObject(slot: cy, objectType: UInt16(StructureType.refinery.rawValue), in: &s))
            s.structures[cy].countDown = 0; s.structures[cy].state = .ready
            // Default map tiles are concrete (groundTileID 0 == builtSlab 0) ⇒ terrain valid; mark the north
            // ring tile player-owned so the adjacency rule passes.
            s.map[Int(corner) - 64].houseID = 0
            #expect(combat.structurePlaceReady(factory: cy, position: corner, in: &s))
        }

        // Count via the find array (not `unitFind`, which skips in-transport units) — the fresh harvester
        // rides its carryall toward the refinery, so it's off-map (`isNotOnMap`).
        func harvesterCount() -> Int {
            s.unitFindArray.filter { s.units[Int($0)].o.type == UInt8(UnitType.harvester.rawValue) }.count
        }

        placeRefinery(at: Tile32.packXY(x: 10, y: 10))
        #expect(harvesterCount() == 1)
        placeRefinery(at: Tile32.packXY(x: 30, y: 30))
        #expect(harvesterCount() == 2)   // the fix: the 2nd refinery gets its own harvester (not gated on the 1st)

        // Each ferried harvester carries its home-refinery `originEncoded` — the carryall-vs-cargo fix:
        // `structurePlaceReady` stamps it on the harvester (the unitCreateWrapper cargo), not the carryall.
        let harvesters = s.unitFindArray.map { Int($0) }.filter { s.units[$0].o.type == UInt8(UnitType.harvester.rawValue) }
        for h in harvesters {
            let origin = try #require(s.indexGetStructure(s.units[h].originEncoded))
            #expect(s.structures[origin].o.type == UInt8(StructureType.refinery.rawValue))
        }
    }

    @Test("carryall/cargo fix: a placed refinery's harvester carries that refinery as its originEncoded")
    func refineryHarvesterOriginEncoded() throws {
        var s = GameState(random256Seed: 0x55, randomLCGSeed: 0x55)
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        s.houses[0].structuresBuilt = 0xFFFFFF; s.houses[0].credits = 5000; s.campaignID = 9
        let combat = UnitCombat(movement: UnitMovement(scriptInfo: info))

        let cy = addFactory(&s, .constructionYard)
        #expect(combat.structureBuildObject(slot: cy, objectType: UInt16(StructureType.refinery.rawValue), in: &s))
        s.structures[cy].countDown = 0; s.structures[cy].state = .ready
        let corner = Tile32.packXY(x: 10, y: 10)
        s.map[Int(corner) - 64].houseID = 0
        #expect(combat.structurePlaceReady(factory: cy, position: corner, in: &s))

        let refinery = try #require((0 ..< s.structures.count).first {
            s.structures[$0].o.flags.contains(.used) && s.structures[$0].o.type == UInt8(StructureType.refinery.rawValue)
        })
        let harvester = try #require(s.unitFindArray.map { Int($0) }.first {
            s.units[$0].o.type == UInt8(UnitType.harvester.rawValue)
        })
        // Before the fix, `unitCreateWrapper` returned the carryall, so `structurePlaceReady` stamped the
        // carryall's originEncoded and the harvester's stayed 0. Now the wrapper returns the cargo (the
        // harvester), so the harvester points to its home refinery — matching OpenDUNE's `Unit_CreateWrapper`.
        #expect(s.units[harvester].originEncoded == s.indexEncode(s.structures[refinery].o.index, type: .structure))
        #expect(s.units[harvester].originEncoded != 0)
    }

    @Test("structure commands route through UnitOrders: repair / upgrade / starport order")
    func structureCommandSeam() {
        var simulation = self.sim()
        let orders = UnitOrders(scriptInfo: info)

        // Repair: a damaged, allocated structure starts self-repairing.
        let win = addFactory(&simulation.state, .windtrap)
        simulation.state.structures[win].o.flags.insert(.allocated)
        simulation.state.structures[win].o.hitpoints = StructureInfo[.windtrap].o.hitpoints - 10
        orders.apply(.repair(structure: UInt16(win)), in: &simulation.state)
        #expect(simulation.state.structures[win].o.flags.contains(.repairing))

        // Upgrade: an upgradable structure starts upgrading.
        let fac = addFactory(&simulation.state, .lightVehicle)
        simulation.state.structures[fac].o.flags.insert(.allocated)
        simulation.state.structures[fac].upgradeTimeLeft = 100
        orders.apply(.upgrade(structure: UInt16(fac)), in: &simulation.state)
        #expect(simulation.state.structures[fac].o.flags.contains(.upgrading))

        // Starport order: an in-stock unit is chained onto the house delivery list.
        let sp = addFactory(&simulation.state, .starport)
        simulation.state.structures[sp].o.houseID = 0
        simulation.state.starportAvailable[Int(UnitType.trike.rawValue)] = 3
        orders.apply(.starportOrder(structure: UInt16(sp), objectType: UInt16(UnitType.trike.rawValue), price: 0), in: &simulation.state)
        #expect(simulation.state.houses[0].starportLinkedID != Pool.unitIndexInvalid)
    }

    @Test("placeReady refuses when the factory isn't ready")
    func placeNotReady() {
        var simulation = self.sim()
        simulation.state.validateStrictIfZero = 1
        let cy = addFactory(&simulation.state, .constructionYard)
        let combat = simulation.unitScript!.combat
        _ = combat.structureBuildObject(slot: cy, objectType: UInt16(StructureType.windtrap.rawValue), in: &simulation.state)
        // Still .busy (not .ready) ⇒ no placement.
        #expect(!combat.structurePlaceReady(factory: cy, position: Tile32.packXY(x: 20, y: 20), in: &simulation.state))
    }

    @Test("placement requires adjacency to a player structure / slab (non-CY)")
    func placementAdjacency() {
        // Player = Atreides (1) so the default tiles (house 0) aren't already player-owned. Strict
        // validation on. Default tiles classify as concrete slab (`groundTileID 0 == builtSlab 0`), so
        // terrain is always valid here — the test isolates the adjacency rule.
        var state = GameState(); state.playerHouseID = 1; state.validateStrictIfZero = 0
        _ = state.houseAllocate(index: 1)
        let combat = UnitCombat(movement: UnitMovement(scriptInfo: info))

        // No player-owned tile nearby ⇒ not adjacent ⇒ rejected.
        let far = Tile32.packXY(x: 30, y: 30)
        #expect(combat.structureIsValidBuildLocation(far, type: .windtrap, in: state) == 0)

        // Mark a tile in the build site's surrounding ring as player-owned ⇒ adjacent ⇒ placeable.
        let corner = Tile32.packXY(x: 10, y: 10)
        state.map[Int(corner) - 64].houseID = 1     // the north ring tile (a player concrete slab)
        #expect(combat.structureIsValidBuildLocation(corner, type: .windtrap, in: state) != 0)
        // (The construction yard is exempt from the adjacency rule — `type != .constructionYard` in the
        // port; not asserted here because the CY is `notOnConcrete` and can't sit on the synthetic
        // concrete-slab test tiles.)
    }

    @Test("placing concrete paints the slab tiles and frees the structure (not a selectable building)")
    func placeConcrete() {
        var state = GameState(); state.playerHouseID = 1
        state.validateStrictIfZero = 1   // bypass terrain/adjacency (covered by placementAdjacency); isolate paint+free
        state.tileIDs.builtSlab = 50
        _ = state.houseAllocate(index: 1)
        let combat = UnitCombat(movement: UnitMovement(scriptInfo: info))

        let corner = Tile32.packXY(x: 10, y: 10)
        let slot = state.structureAllocate(index: Pool.structureIndexInvalid,
                                           type: UInt8(StructureType.slab2x2.rawValue))!
        state.structures[slot].o.houseID = 1
        state.structures[slot].o.flags.insert(.isNotOnMap)

        #expect(combat.structurePlace(slot, position: corner, in: &state))
        #expect(!state.structures[slot].o.flags.contains(.used))      // the structure was freed
        #expect(state.structureGetByPackedTile(corner) == nil)        // ⇒ nothing selectable there
        // The 2×2 footprint is painted as the owner's concrete (builtSlab) tiles — not a baked structure sprite.
        let layout = StructureLayoutInfo[StructureInfo[.slab2x2].layout]
        for i in 0 ..< Int(layout.tileCount) {
            let p = Int(corner) + Int(layout.tiles[i])
            #expect(state.map[p].groundTileID == 50)
            #expect(state.map[p].houseID == 1)
        }
    }

    @Test("the Command seam routes build/cancel through UnitOrders")
    func commandSeam() {
        var simulation = self.sim()
        let fac = addFactory(&simulation.state, .lightVehicle)
        let orders = UnitOrders(scriptInfo: info)
        orders.apply(.build(structure: UInt16(fac), objectType: UInt16(UnitType.trike.rawValue)), in: &simulation.state)
        #expect(simulation.state.structures[fac].state == .busy)
        #expect(simulation.state.structures[fac].o.linkedID != 0xFF)
        orders.apply(.cancelBuild(structure: UInt16(fac)), in: &simulation.state)
        #expect(simulation.state.structures[fac].o.linkedID == 0xFF)
        #expect(simulation.state.structures[fac].countDown == 0)
    }
}
