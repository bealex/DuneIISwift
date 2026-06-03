import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// A scenario-level integration test of the **full harvester economy loop** under the *real* `UNIT.EMC` +
/// `BUILD.EMC` scripts: a harvester gathers spice → returns to the refinery → docks → the refinery refines
/// it into credits → the harvester redeploys → harvests again. The native-level pieces are covered by
/// `HarvesterTests`/`CarryallTests`/`SearchSpiceTests`; this drives the whole cycle through the live
/// `Simulation` to catch a break anywhere in the chain. Short-circuits if the committed scripts are absent.
@Suite("Harvester cycle (real scripts)")
struct HarvesterCycleTests {
    @Test("harvest → return → refine → redeploy → harvest again", .timeLimit(.minutes(1)))
    func fullCycle() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/SimulationTests → repo
        guard
            let unitData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let buildData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
            let iconData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP"))
        else { return }

        let unitInfo = ScriptInfo(try Emc.Program(unitData))
        let buildInfo = ScriptInfo(try Emc.Program(buildData))
        let iconMap = try IconMap(iconData)

        var state = GameState()
        state.playerHouseID = 0
        _ = state.houseAllocate(index: 0)
        state.houses[0].unitCountMax = 100
        state.houses[0].credits = 1000
        state.playerCreditsNoSilo = 5000  // keep starting credits from being clamped before a silo exists
        state.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        state.iconMap = iconMap  // structureUpdateMap needs it to stamp tiles
        state.mapScale = 0  // the default map is all rock

        // A thick-spice patch around (20,20) — plenty for several harvest loads.
        let thickSpice = state.tileIDs.landscape &+ 80
        for y in 18 ... 22 {
            for x in 18 ... 22 {
                state.map[Int(Tile32.packXY(x: UInt16(x), y: UInt16(y)))].groundTileID = thickSpice
            }
        }

        // An idle refinery built *adjacent* to the spice (its east edge), as a player actually places one.
        // This matters: after refining, the harvester is redeployed onto a free ring tile nearest the spice
        // and resumes HARVEST by searching within radius 3 (the escalating wider search is, per UNIT.EMC,
        // for AI harvesters only). A refinery a long drive from spice would faithfully leave the deployed
        // player harvester with nothing in range — it STOPs, exactly as OpenDUNE does.
        let ref = state.structureAllocate(
            index: Pool.structureIndexInvalid,
            type: UInt8(StructureType.refinery.rawValue)
        )!
        let refCorner = Tile32.unpack(Tile32.packXY(x: 23, y: 20))
        state.structures[ref].o.houseID = 0
        state.structures[ref].o.position = Tile32(x: refCorner.x & 0xFF00, y: refCorner.y & 0xFF00)
        state.structures[ref].state = .idle
        state.structures[ref].o.hitpoints = StructureInfo[.refinery].o.hitpoints
        state.structures[ref].hitpointsMax = StructureInfo[.refinery].o.hitpoints
        state.structures[ref].o.linkedID = 0xFF
        state.structureUpdateMap(ref)

        // A harvester just *west* of the spice, ordered to HARVEST (loads its real script). It must drive
        // onto the spice — which is what sets `targetLast` (the remembered harvest spot, `unit.c:1453`), so
        // the post-refine deploy summons a carryall back to it, exactly as in a real game. (Teleporting the
        // harvester directly onto spice leaves `targetLast == 0`, an unreachable state that forces the
        // walk-out deploy path.)
        let harv = state.unitAllocate(index: 0, type: UInt8(UnitType.harvester.rawValue), houseID: 0)!
        state.units[harv].o.position = Tile32.unpack(Tile32.packXY(x: 16, y: 20))
        state.units[harv].o.hitpoints = UnitInfo[.harvester].o.hitpoints
        UnitActions().setAction(
            slot: harv,
            action: UInt8(ActionType.harvest.rawValue),
            scriptInfo: unitInfo,
            in: &state
        )
        state.unitUpdateMap(1, harv)

        var sim = Simulation(state: state, scriptInfo: unitInfo, structureScriptInfo: buildInfo)
        let creditsStart = sim.state.houses[0].credits

        // Drive the loop and record each phase as it happens.
        var harvested = false  // gathered spice (amount > 0)
        var docked = false  // entered the refinery (it received the harvester)
        var refined = false  // credits rose (spice → money)
        var emptiedAfterDock = false  // back on the map, unloaded
        var harvestedAgain = false  // a *second* harvest after the round trip — the full loop closed

        for _ in 0 ..< 14000 {
            sim.tick()
            let h = sim.state.units[harv]
            if h.amount > 0 { harvested = true }
            if sim.state.structures[ref].o.linkedID != 0xFF { docked = true }
            if sim.state.houses[0].credits > creditsStart { refined = true }
            if docked && h.amount == 0 && !h.o.flags.contains(.isNotOnMap) { emptiedAfterDock = true }
            if emptiedAfterDock && h.amount > 0 { harvestedAgain = true; break }
        }

        #expect(harvested, "the harvester never gathered spice")
        #expect(docked, "the harvester never returned + docked at the refinery")
        #expect(refined, "the refinery never converted spice into credits")
        #expect(emptiedAfterDock, "the harvester never redeployed empty after refining")
        // The full loop closes: the redeployed empty harvester resumes HARVEST and gathers spice again.
        #expect(harvestedAgain, "the redeployed harvester never resumed harvesting (the loop didn't close)")
    }
}
