import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import DuneIISimulation
@testable import DuneIIScenarios

/// Builds each predefined scenario from the real `ICON.MAP` + `UNIT.EMC` and checks the layout (unit
/// placement, initial action / target / destination, building). Running ticks must not crash; until the
/// movement/combat natives land the units stay put (the golden trajectory becomes non-trivial then).
@Suite("Scenario builder + runner")
struct ScenarioBuilderTests {
    private func loadBuilder() throws -> ScenarioBuilder? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/ScenariosTests → repo root
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let emc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc"))
        else { return nil }
        return ScenarioBuilder(iconMap: try IconMap(icon), unitScript: ScriptInfo(try Emc.Program(emc)))
    }

    @Test("moving: the mover sits at 0:0 with a Move action + destination 7:7; ticks stay static for now")
    func moving() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .moving, unit1: .tank, unit2: .trike, terrainSeed: 1))
        #expect(world.unitSlots.count == 1)
        let slot = world.unitSlots[0]
        #expect(world.state.units[slot].o.position.packed == world.terrain.mapPacked(lx: 0, ly: 0))
        #expect(world.state.units[slot].actionID == UInt8(ActionType.move.rawValue))
        #expect(world.state.units[slot].currentDestination.packed == world.terrain.mapPacked(lx: 7, ly: 7))
        #expect(world.runner.interpreter.isLoaded(world.state.units[slot].o.script))   // move script loaded

        let frames = world.run(ticks: 5)
        #expect(frames.count == 6)
        #expect(frames.first?[0].packed == frames.last?[0].packed)   // no movement native yet ⇒ static
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
        #expect(world.state.units[u2].currentDestination.packed == world.terrain.mapPacked(lx: 2, ly: 2))
    }

    @Test("moveAroundBuilding: a building is stamped in the centre and the mover starts at 0:0")
    func moveAroundBuilding() throws {
        guard let builder = try loadBuilder() else { return }
        let world = builder.build(TestScenario(kind: .moveAroundBuilding, unit1: .tank, unit2: .tank, terrainSeed: 1))
        let centre = Int(world.terrain.mapPacked(lx: 3, ly: 3))
        #expect(world.state.map[centre].hasStructure)
        #expect(world.state.units[world.unitSlots[0]].o.position.packed == world.terrain.mapPacked(lx: 0, ly: 0))
    }
}
