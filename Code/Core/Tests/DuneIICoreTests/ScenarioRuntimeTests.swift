import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

/// End-to-end tests against `ScenarioRuntime` — the same code path
/// `ScenarioScene` and `duneii-headless` exercise. Gated on the real
/// install because `AssetLoader` needs the PAKs. Tests cover:
///  - scenario load populates the expected mission-1 starting state
///  - click / right-click routing (select, deselect, move, attack)
///  - yard selection via map click
///  - full build-enqueue → tick → sidebar → commit cycle
///  - tile-grid stamping after placement (concrete slab + structure)
///  - pathfinder routes around a scenario-spawned CYARD
///  - harvester-less mission 1 doesn't crash harvesting passes
@MainActor
@Suite("ScenarioRuntime — end-to-end mission-1 flows")
struct ScenarioRuntimeTests {

    /// Builds a runtime loaded on mission 1 (SCENA001.INI), or `nil`
    /// when the install can't be located.
    private func loadMission1() throws -> ScenarioRuntime? {
        guard let installDir = TestInstall.locate() else { return nil }
        let installation = try Installation(rootDirectory: installDir)
        let assets = try AssetLoader(installation: installation)
        let runtime = ScenarioRuntime(assets: assets)
        try runtime.load(scenarioName: "SCENA001.INI")
        return runtime
    }

    // MARK: Load

    @Test("Mission 1 loads with 1 structure (CYARD), 17 units, credits=1000")
    func mission1Load() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        #expect(host.structures.findArray.count == 1)
        #expect(host.units.findArray.count == 17)
        let cy = host.structures.slots[host.structures.findArray[0]]
        #expect(cy.type == 8)                                   // CYARD
        #expect(cy.houseID == Simulation.House.atreides)
        #expect(r.buildController.selectedYardIndex == host.structures.findArray[0])
        #expect(host.houses.slots[Int(Simulation.House.atreides)].credits == 1000)
    }

    @Test("Mission 1 has NO harvester at start (user-reported)")
    func noStartingHarvester() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        let harvesters = host.units.findArray.filter { host.units.slots[$0].type == 16 }
        #expect(harvesters.isEmpty)
    }

    @Test("Scenario-spawned CYARD stamps hasStructure=true onto footprint tiles")
    func cyardStampedOnLoad() throws {
        guard let r = try loadMission1() else { return }
        // CYARD anchor in SCENA001 is (30, 25). Footprint (30,25)(31,25)(30,26)(31,26).
        for (fx, fy) in [(30, 25), (31, 25), (30, 26), (31, 26)] {
            let idx = fy * 64 + fx
            let cell = r.tileGrid[idx]
            #expect(cell.hasStructure == true,
                "expected hasStructure=true at (\(fx),\(fy))")
            #expect(cell.houseID == Simulation.House.atreides,
                "expected CYARD owner at (\(fx),\(fy))")
        }
    }

    // MARK: Click routing

    @Test("Left-click on a friendly unit tile selects that unit")
    func clickFriendlySelectsUnit() throws {
        guard let r = try loadMission1() else { return }
        // Atreides TRIKE at tile (29, 23).
        let outcome = r.leftClick(tileX: 29, tileY: 23)
        guard case .unitSelected(let idx) = outcome else {
            Issue.record("expected unitSelected, got \(outcome)")
            return
        }
        #expect(r.host?.units.slots[idx].type == 13)
        #expect(r.commandController.selectedUnitIndex == idx)
    }

    @Test("Left-click on empty tile with selection deselects; with no selection does nothing")
    func clickEmptyDeselects() throws {
        guard let r = try loadMission1() else { return }
        _ = r.leftClick(tileX: 29, tileY: 23)                    // select
        let deselect = r.leftClick(tileX: 40, tileY: 40)         // empty
        #expect(deselect == .unitDeselected)
        #expect(r.commandController.selectedUnitIndex == nil)

        let noop = r.leftClick(tileX: 45, tileY: 45)              // still empty
        #expect(noop == .none)
    }

    @Test("Left-click on enemy unit selects it but as non-friendly (info-only)")
    func clickEnemySelectsInfoOnly() throws {
        guard let r = try loadMission1() else { return }
        // Ordos SOLDIER at (30, 19).
        let outcome = r.leftClick(tileX: 30, tileY: 19)
        if case .unitSelected = outcome {
            // ok — selection happened
        } else {
            Issue.record("expected unitSelected, got \(outcome)")
        }
        #expect(r.commandController.selectedUnitIndex != nil)
        #expect(r.commandController.isFriendlySelection == false)
        // Right-click is now inert because selection is info-only.
        let rOutcome = r.rightClick(tileX: 35, tileY: 35)
        #expect(rOutcome == .none)
    }

    @Test("Right-click with selection on empty tile issues orderMove")
    func rightClickMoves() throws {
        guard let r = try loadMission1() else { return }
        _ = r.leftClick(tileX: 29, tileY: 23)
        let outcome = r.rightClick(tileX: 35, tileY: 30)
        guard case .orderMove(let idx, let tx, let ty, let ok) = outcome else {
            Issue.record("expected orderMove, got \(outcome)")
            return
        }
        #expect(ok == true)
        #expect(tx == 35 && ty == 30)
        #expect(r.host?.units.slots[idx].actionID == Simulation.ActionID.move)
    }

    @Test("Right-click with friendly unit on enemy structure issues orderAttackStructure")
    func rightClickAttacksStructure() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        // Manually plant an enemy structure to attack. Mutate through
        // a local copy + write-back so the class property actually
        // updates (chained `.allocate` on a class var goes through
        // modify but subsequent subscript writes need the same
        // pattern).
        var structs = host.structures
        _ = structs.allocate(
            at: 7, type: 12 /* REFINERY */, houseID: Simulation.House.harkonnen
        )
        var s = structs[7]
        // Plant far from any scenario unit so only the structure hits
        // the right-click. Mission 1's Ordos units sit around (40, 30)
        // and (43, 38); (50, 50) is clear.
        s.positionX = UInt16(50 * 256)
        s.positionY = UInt16(50 * 256)
        structs[7] = s
        host.structures = structs

        _ = r.leftClick(tileX: 29, tileY: 23)        // select friendly trike
        #expect(r.commandController.selectedUnitIndex != nil)
        #expect(r.commandController.isFriendlySelection == true)

        let outcome = r.rightClick(tileX: 50, tileY: 50)
        guard case .orderAttackStructure(_, let targetIdx, let ok) = outcome else {
            Issue.record("expected orderAttackStructure, got \(outcome)")
            return
        }
        #expect(targetIdx == 7)
        #expect(ok)
    }

    @Test("Right-click with selection on enemy unit issues orderAttack")
    func rightClickAttacks() throws {
        guard let r = try loadMission1() else { return }
        _ = r.leftClick(tileX: 29, tileY: 23)                    // select trike
        let outcome = r.rightClick(tileX: 30, tileY: 19)         // enemy tile
        guard case .orderAttack(_, _, let ok) = outcome else {
            Issue.record("expected orderAttack, got \(outcome)")
            return
        }
        #expect(ok == true)
    }

    // MARK: Build flow

    @Test("Full construction cycle: enqueue slab → tick → sidebar → place → tile stamped")
    func buildSlabEndToEnd() throws {
        guard let r = try loadMission1() else { return }
        // Manually enqueue slab (type 0) — exercises startConstruction.
        let host = try #require(r.host)
        var pool = host.structures
        let ok = Simulation.Structures.startConstruction(
            yardIndex: r.buildController.selectedYardIndex!,
            objectType: 0, pool: &pool
        )
        host.structures = pool
        #expect(ok)
        r.refreshBuildState()
        #expect(r.buildController.yardState == .busy)
        #expect(r.buildController.countDown == 4096)     // buildTime=16 << 8

        // Tick 30 — more than enough for slab (buildTime=16).
        r.tick(30)
        #expect(r.buildController.yardState == .ready)
        #expect(r.buildController.countDown == 0)

        // Sidebar click on row 0 (first available is slab, sortPriority 2) → placementStarted.
        let sb = r.sidebarClick(row: 0)
        guard case .placementStarted(let t) = sb, t == 0 else {
            Issue.record("expected placementStarted(0), got \(sb)")
            return
        }

        // Commit at (29, 25) — entirelyRock, adjacent to CYARD.
        let commit = r.leftClick(tileX: 29, tileY: 25)
        guard case .placementCommitted(let type, _, let x, let y, _) = commit else {
            Issue.record("expected placementCommitted, got \(commit)")
            return
        }
        #expect(type == 0)
        #expect(x == 29 && y == 25)

        // Tile should be stamped as concrete.
        let cell = r.tileGrid[25 * 64 + 29]
        let resolver = r.assets.tileResolver
        let landscape = resolver.landscapeType(
            groundTileID: cell.groundTileID,
            overlayTileID: cell.overlayTileID,
            hasStructure: cell.hasStructure
        )
        #expect(landscape == .concreteSlab)
        #expect(cell.houseID == Simulation.House.atreides)

        // CYARD should have flipped back to IDLE.
        let yard = host.structures.slots[r.buildController.selectedYardIndex!]
        #expect(yard.state == Simulation.StructureState.idle.rawValue)
        #expect(yard.objectType == 0xFFFF)
    }

    @Test("Placed structure stamps iconGroup tiles onto the runtime tileGrid")
    func structureStampsIconGroupTiles() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        let yardIdx = r.buildController.selectedYardIndex!

        // Slab up 2x2 at (28..29, 25..26) so windtrap validity is fully valid.
        for (x, y) in [(29, 25), (29, 26), (28, 25), (28, 26)] {
            var pool = host.structures
            _ = Simulation.Structures.startConstruction(
                yardIndex: yardIdx, objectType: 0, pool: &pool
            )
            host.structures = pool
            r.tick(30)
            _ = r.sidebarClick(row: 0)
            _ = r.leftClick(tileX: x, tileY: y)
        }

        // Build windtrap at (28, 25).
        var pool = host.structures
        _ = Simulation.Structures.startConstruction(
            yardIndex: yardIdx, objectType: 9, pool: &pool
        )
        host.structures = pool
        r.tick(100)
        _ = r.sidebarClick(row: 1)
        let commit = r.leftClick(tileX: 28, tileY: 25)
        guard case .placementCommitted = commit else {
            Issue.record("placement failed: \(commit)")
            return
        }

        // After stamping, the windtrap's 4 footprint tiles should have
        // non-default groundTileIDs drawn from the windtrap iconGroup.
        let grid = r.tileGrid
        let preSlabGroundID = Simulation.WorldSnapshot.Tile(
            groundTileID: 0, overlayTileID: 0, houseID: 0,
            isUnveiled: false, hasUnit: false, hasStructure: false,
            hasAnimation: false, hasExplosion: false, objectRef: 0
        ).groundTileID
        for (fx, fy) in [(28, 25), (29, 25), (28, 26), (29, 26)] {
            let cell = grid[fy * 64 + fx]
            #expect(cell.hasStructure == true, "footprint (\(fx),\(fy)) hasStructure=true")
            #expect(cell.groundTileID != preSlabGroundID, "footprint (\(fx),\(fy)) should carry a real sprite")
            #expect(cell.houseID == Simulation.House.atreides)
        }
    }

    @Test("Building a windtrap requires 4 slabs of concrete; unlocks refinery type=12")
    func windtrapUnlocksRefinery() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        let yardIdx = r.buildController.selectedYardIndex!

        // Concrete (28-29, 25-26) — 4 slabs.
        for (x, y) in [(29, 25), (29, 26), (28, 25), (28, 26)] {
            var pool = host.structures
            _ = Simulation.Structures.startConstruction(
                yardIndex: yardIdx, objectType: 0, pool: &pool
            )
            host.structures = pool
            r.tick(30)
            _ = r.sidebarClick(row: 0)
            _ = r.leftClick(tileX: x, tileY: y)
        }

        // Validity for windtrap at (28, 25) should now be fully valid.
        let v = r.placementValidity(type: 9, tileX: 28, tileY: 25)
        #expect(v == 1)

        // Queue windtrap, wait, place.
        var pool = host.structures
        _ = Simulation.Structures.startConstruction(
            yardIndex: yardIdx, objectType: 9, pool: &pool
        )
        host.structures = pool
        r.tick(100)
        // Windtrap is row 1 in [0, 9].
        _ = r.sidebarClick(row: 1)
        let commit = r.leftClick(tileX: 28, tileY: 25)
        guard case .placementCommitted(let type, _, _, _, let degraded) = commit else {
            Issue.record("expected placementCommitted, got \(commit)")
            return
        }
        #expect(type == 9)
        #expect(degraded == false)        // all 4 tiles on concrete

        // BuildController.availableTypes should now include REFINERY (12).
        r.refreshBuildState()
        #expect(r.buildController.availableTypes.contains(12))
    }

    @Test("Placing a refinery spawns a harvester for the player (no carryall ferry)")
    func refineryPlacementSpawnsHarvester() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        let yardIdx = r.buildController.selectedYardIndex!

        // Slab 2x2 area adjacent to CYARD so we can put a windtrap.
        for (x, y) in [(29, 25), (29, 26), (28, 25), (28, 26)] {
            var pool = host.structures
            _ = Simulation.Structures.startConstruction(
                yardIndex: yardIdx, objectType: 0, pool: &pool
            )
            host.structures = pool
            r.tick(30)
            _ = r.sidebarClick(row: 0)
            _ = r.leftClick(tileX: x, tileY: y)
        }
        // Build windtrap.
        var pool = host.structures
        _ = Simulation.Structures.startConstruction(
            yardIndex: yardIdx, objectType: 9, pool: &pool
        )
        host.structures = pool
        r.tick(100)
        _ = r.sidebarClick(row: 1)
        _ = r.leftClick(tileX: 28, tileY: 25)

        // REFINERY is 3x2; needs 6 slabs. For test simplicity place
        // it on the sand west of the CYARD (degraded HP is fine).
        // Build it via the enqueue path.
        var pool2 = host.structures
        _ = Simulation.Structures.startConstruction(
            yardIndex: yardIdx, objectType: 12, pool: &pool2
        )
        host.structures = pool2
        r.tick(120)
        r.refreshBuildState()
        // Refinery is row 2 in available=[0, 9, 12].
        _ = r.sidebarClick(row: 2)
        // Place at (28, 27) — 3×2 footprint (28..30, 27..28) on rock,
        // adjacent to both the windtrap and the CYARD. All 6 tiles
        // need slab (validity = -6 = valid but degraded), which is
        // fine for this test.
        let commit = r.leftClick(tileX: 28, tileY: 27)
        guard case .placementCommitted = commit else {
            Issue.record("refinery placement failed: \(commit)")
            return
        }

        // Expect a harvester to exist for the Atreides.
        let harvesters = host.units.findArray.filter {
            host.units.slots[$0].type == 16
                && host.units.slots[$0].houseID == Simulation.House.atreides
        }
        #expect(harvesters.count == 1, "expected 1 player harvester after refinery, got \(harvesters.count)")
        if let hIdx = harvesters.first {
            // Harvester spawned in HARVEST action so the auto-seek
            // cycle picks it up on the next tickHarvesting pass.
            #expect(host.units.slots[hIdx].actionID == Simulation.ActionID.harvest)
        }
    }

    // MARK: Pathfinder live-structure awareness

    @Test("Pathfinder routes a TRIKE around the CYARD rather than through it")
    func pathfinderAvoidsCyard() throws {
        guard let r = try loadMission1() else { return }
        // Select Atreides trike at (29, 23). Order it to (50, 50) —
        // direct SE path would cross CYARD at (30,25)(31,25)(30,26)(31,26).
        _ = r.leftClick(tileX: 29, tileY: 23)
        _ = r.rightClick(tileX: 50, tileY: 50)

        // Tick enough for the UNIT.EMC CalculateRoute to run. Scripts
        // dispatch inside tick(), but orderMove + calculateRoute run on
        // sequential passes — 20 ticks is plenty.
        r.tick(20)

        // Inspect the trike's route — at least one step should not be
        // "all direction 3" (SE). A clear path around the CYARD requires
        // mixing E + SE + S steps.
        let host = try #require(r.host)
        let u = host.units.slots[4]
        let routeBytes = u.route.prefix { $0 != 0xFF }
        #expect(!routeBytes.isEmpty)
        let seCount = routeBytes.filter { $0 == 3 }.count
        let others = routeBytes.count - seCount
        // Post-stamp, we should see a mix (E, S, SE) not a straight line.
        #expect(others >= 1, "expected mixed directions, got \(Array(routeBytes))")
    }

    // MARK: Harvesting edge case

    @Test("Mission 1 (no harvester) doesn't crash the harvesting pass")
    func harvestingPassWithoutHarvester() throws {
        guard let r = try loadMission1() else { return }
        // Tick enough to trigger multiple harvesting passes (cadence=3).
        r.tick(30)
        // Just verifying no crash and no unexpected mutations.
        let host = try #require(r.host)
        #expect(host.units.findArray.count == 17)
    }

    // MARK: Yard-select via map click

    @Test("Left-click on player CYARD keeps it selected (no-op when already selected)")
    func clickOwnYardWhenAlreadySelected() throws {
        guard let r = try loadMission1() else { return }
        let before = r.buildController.selectedYardIndex
        let outcome = r.leftClick(tileX: 30, tileY: 25)
        // The generic structure-select pass sets selectedStructureIndex
        // to the CYARD too, so the outcome reports structureSelected.
        if case .structureSelected = outcome {
            // ok
        } else if outcome == .none {
            // also acceptable — if selectedStructureIndex was already set
        } else {
            Issue.record("expected structureSelected or none, got \(outcome)")
        }
        #expect(r.buildController.selectedYardIndex == before)
        #expect(r.selectedStructureIndex == before)
    }

    @Test("Left-click on any structure sets selectedStructureIndex (info surface)")
    func clickStructureSetsSelection() throws {
        guard let r = try loadMission1() else { return }
        // CYARD footprint includes (30, 25). Click on any tile.
        _ = r.leftClick(tileX: 30, tileY: 25)
        let host = try #require(r.host)
        let cyIdx = host.structures.findArray.first { host.structures.slots[$0].type == 8 }!
        #expect(r.selectedStructureIndex == cyIdx)
    }

    @Test("Clicking a unit after selecting a structure clears the structure selection")
    func clickUnitClearsStructureSelection() throws {
        guard let r = try loadMission1() else { return }
        _ = r.leftClick(tileX: 30, tileY: 25)        // select CYARD
        #expect(r.selectedStructureIndex != nil)
        _ = r.leftClick(tileX: 29, tileY: 23)        // select friendly TRIKE
        #expect(r.selectedStructureIndex == nil)
        #expect(r.commandController.selectedUnitIndex != nil)
    }

    @Test("deselect() clears unit + structure + placement selections")
    func deselectClearsAll() throws {
        guard let r = try loadMission1() else { return }
        _ = r.leftClick(tileX: 29, tileY: 23)    // select trike
        _ = r.leftClick(tileX: 30, tileY: 25)    // select CYARD
        // Both a structure selection (CYARD) and the prior unit
        // selection get recorded across these clicks — verify deselect
        // wipes the whole slate.
        r.buildController.placementType = 9       // simulate placement mode
        r.deselect()
        #expect(r.commandController.selectedUnitIndex == nil)
        #expect(r.commandController.isFriendlySelection == false)
        #expect(r.selectedStructureIndex == nil)
        #expect(r.buildController.placementType == nil)
    }

    @Test("cycleToNextPlayerUnit steps through friendly units, skipping enemies")
    func cycleSelection() throws {
        guard let r = try loadMission1() else { return }
        // Atreides units in mission 1: slots 2, 4, 5, 6, 8 (from the
        // scenario dump). Cycling should walk through them in order.
        let first = r.cycleToNextPlayerUnit()
        #expect(first == 2)
        let second = r.cycleToNextPlayerUnit()
        #expect(second == 4)
        let third = r.cycleToNextPlayerUnit()
        #expect(third == 5)
    }

    @Test("BuildController.yardState surface stays in sync after tick() — no stale UI state")
    func tickRefreshesYardState() throws {
        guard let r = try loadMission1() else { return }
        let host = try #require(r.host)
        var pool = host.structures
        _ = Simulation.Structures.startConstruction(
            yardIndex: r.buildController.selectedYardIndex!,
            objectType: 0, pool: &pool
        )
        host.structures = pool
        r.refreshBuildState()
        #expect(r.buildController.yardState == .busy)
        r.tick(30)
        // Without the tick-refresh fix, controller would still say BUSY here.
        #expect(r.buildController.yardState == .ready)
    }
}
