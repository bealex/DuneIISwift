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

    @Test("each placed refinery spawns its own harvester (a 2nd refinery ⇒ a 2nd harvester)")
    func refineryHarvesterPerPlacement() {
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
