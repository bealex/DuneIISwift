import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import DuneIISimulation
@testable import DuneIIScenarios

/// Builds each predefined scenario from the real `ICON.MAP` + `UNIT.EMC` and checks the layout (unit
/// placement, initial action / target / destination, building). With the movement cluster ported, a
/// `moving` unit now actually crosses the terrain when ticked (via the full `Simulation.tick()`).
@Suite("Scenario builder + runner")
struct ScenarioBuilderTests {
    private func loadBuilder() throws -> ScenarioBuilder? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/ScenariosTests → repo root
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let emc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
              let build = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc"))
        else { return nil }
        return ScenarioBuilder(iconMap: try IconMap(icon), unitScript: ScriptInfo(try Emc.Program(emc)),
                               structureScript: ScriptInfo(try Emc.Program(build)))
    }

    @Test("moving: the mover starts at 0:0 with Move + targetMove 7:7, then actually crosses the terrain")
    func moving() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .moving, unit1: .tank, unit2: .trike, terrainSeed: 1))
        #expect(world.unitSlots.count == 1)
        let slot = world.unitSlots[0]
        #expect(world.state.units[slot].o.position.packed == world.terrain.mapPacked(lx: 0, ly: 0))
        #expect(world.state.units[slot].actionID == UInt8(ActionType.move.rawValue))
        #expect(world.state.units[slot].targetMove
                == world.state.indexEncode(world.terrain.mapPacked(lx: 7, ly: 7), type: .tile))
        #expect(world.state.units[slot].currentDestination.packed == 0)   // route not committed yet
        #expect(world.runner.interpreter.isLoaded(world.state.units[slot].o.script))   // move script loaded

        // With the movement cluster ported, ticking the full Simulation loop drives the unit toward 7:7.
        let frames = world.run(ticks: 300)
        #expect(frames.count == 301)
        let start = frames.first![0], end = frames.last![0]
        #expect(end != start)                              // it rotated + moved (not static)
        #expect(end.packed != start.packed)                // it physically advanced from 0:0
    }

    @Test("closeAttack: two enemy-house units adjacent; the attacker targets the defender")
    func closeAttack() throws {
        guard let builder = try loadBuilder() else { return }
        let world = builder.build(TestScenario(kind: .closeAttack, unit1: .tank, unit2: .tank, terrainSeed: 1))
        #expect(world.unitSlots.count == 2)
        let (u1, u2) = (world.unitSlots[0], world.unitSlots[1])
        #expect(world.state.units[u1].o.houseID != world.state.units[u2].o.houseID)
        #expect(world.state.units[u2].targetAttack
                == world.state.indexEncode(world.state.units[u1].o.index, type: .unit))
        #expect(world.runner.interpreter.isLoaded(world.state.units[u2].o.script))   // attack script loaded
        #expect(world.state.units[u1].o.hitpoints > 0)   // defender has real HP
    }

    @Test("guarding: the guard sits at 2:2 in Guard; the mover heads toward it")
    func guarding() throws {
        guard let builder = try loadBuilder() else { return }
        let world = builder.build(TestScenario(kind: .guarding, unit1: .tank, unit2: .trike, terrainSeed: 1))
        let (u1, u2) = (world.unitSlots[0], world.unitSlots[1])
        #expect(world.state.units[u1].actionID == UInt8(ActionType.guard_.rawValue))
        #expect(world.state.units[u1].o.position.packed == world.terrain.mapPacked(lx: 2, ly: 2))
        #expect(world.state.units[u2].targetMove
                == world.state.indexEncode(world.terrain.mapPacked(lx: 2, ly: 2), type: .tile))
    }

    @Test("moveAroundBuilding: a building is stamped in the centre and the mover starts at 0:0")
    func moveAroundBuilding() throws {
        guard let builder = try loadBuilder() else { return }
        let world = builder.build(TestScenario(kind: .moveAroundBuilding, unit1: .tank, unit2: .tank, terrainSeed: 1))
        let centre = Int(world.terrain.mapPacked(lx: 3, ly: 3))
        #expect(world.state.map[centre].hasStructure)
        #expect(world.state.units[world.unitSlots[0]].o.position.packed == world.terrain.mapPacked(lx: 0, ly: 0))
    }

    @Test("deviate: the enemy deviator mind-controls the player unit, which flips to the enemy house")
    func deviate() throws {
        guard let builder = try loadBuilder() else { return }
        let world = builder.build(TestScenario(kind: .deviate, unit1: .tank, unit2: .deviator, terrainSeed: 1))
        let victim = world.unitSlots[0]
        #expect(world.state.units[victim].o.houseID == UInt8(HouseID.harkonnen.rawValue))   // still owned by player
        #expect(world.state.units[victim].deviated == 120)                                  // but deviated
        #expect(world.state.units[victim].deviatedHouse == UInt8(HouseID.ordos.rawValue))   // by the enemy
        #expect(world.state.unitHouseID(world.state.units[victim]) == UInt8(HouseID.ordos.rawValue))  // renders as Ordos
        #expect(world.state.units[victim].targetAttack == 0 && world.state.units[victim].targetMove == 0)
    }

    @Test("attackStructure: the tank damages the enemy windtrap (Structure_Damage runs in the loop)")
    func attackStructureRuns() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .attackStructure, unit1: .tank, unit2: .tank, terrainSeed: 42))
        let fullHP = try #require(world.state.structures.first(where: { $0.o.flags.contains(.used) })).o.hitpoints
        for _ in 0 ..< 250 { world.tick() }
        // The windtrap took damage (or was destroyed → removed) — the structure-damage path ran end-to-end.
        let after = world.state.structures.first(where: { $0.o.flags.contains(.used) })
        #expect(after == nil || after!.o.hitpoints < fullHP)
    }

    @Test("turretDefense: the turret's script fires — a bullet spawns over ticks")
    func turretFires() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .turretDefense, unit1: .tank, unit2: .tank, terrainSeed: 42))
        var fired = false
        for _ in 0 ..< 300 where !fired {
            world.tick()
            fired = world.state.units.contains { $0.o.flags.contains(.used) && $0.o.type == UInt8(UnitType.bullet.rawValue) }
        }
        #expect(fired)
    }
}
