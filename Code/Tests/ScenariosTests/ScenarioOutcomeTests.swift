import DuneIIContracts
import DuneIIFormats
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIScenarios

/// `ScenarioWorld.outcome()` — the lab's "scenario finished" signal. Each kind reaches its natural
/// endpoint when ticked; a fresh scenario is still `.running`.
@Suite("Scenario outcome")
struct ScenarioOutcomeTests {
    private func loadBuilder() throws -> ScenarioBuilder? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/ScenariosTests → repo root
        guard
            let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
            let emc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let build = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc"))
        else { return nil }
        return ScenarioBuilder(
            iconMap: try IconMap(icon),
            unitScript: ScriptInfo(try Emc.Program(emc)),
            structureScript: ScriptInfo(try Emc.Program(build))
        )
    }

    @Test("a freshly-built scenario is still running")
    func freshIsRunning() throws {
        guard let builder = try loadBuilder() else { return }
        let world = builder.build(TestScenario(kind: .factoryProduce, unit1: .tank, unit2: .tank, terrainSeed: 42))
        #expect(world.outcome() == .running)
    }

    @Test("factoryProduce finishes once the unit is built (READY)")
    func factoryFinishes() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .factoryProduce, unit1: .tank, unit2: .tank, terrainSeed: 42))
        for _ in 0 ..< 250 { world.tick() }
        #expect(world.outcome() == .finished("Unit built (READY)"))
    }

    @Test("attackStructure finishes when the building is destroyed")
    func attackStructureFinishes() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .attackStructure, unit1: .tank, unit2: .tank, terrainSeed: 42))
        for _ in 0 ..< 250 { world.tick() }
        #expect(world.outcome() == .finished("Building destroyed"))
    }

    @Test("upgradeBuilding finishes when the barracks reaches level 1")
    func upgradeFinishes() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .upgradeBuilding, unit1: .tank, unit2: .tank, terrainSeed: 42))
        for _ in 0 ..< 300 { world.tick() }
        #expect(world.outcome() == .finished("Upgraded to level 1"))
    }
}
