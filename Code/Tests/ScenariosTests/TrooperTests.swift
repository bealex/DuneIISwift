import DuneIIContracts
import DuneIIFormats
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIScenarios

/// Infantry/trooper behaviour in the lab: the walk animation (`tickUnknown5` advances `spriteOffset`) and
/// the death path (the DIE branch `StartAnimation` 0x04 → `Die` 0x0F now removes them).
@Suite("Troopers walk + die")
struct TrooperTests {
    private func loadBuilder() throws -> ScenarioBuilder? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
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

    @Test("a walking trooper animates — spriteOffset advances through the walk cycle")
    func walkAnimates() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .moving, unit1: .troopers, unit2: .tank, terrainSeed: 42))
        let slot = world.unitSlots[0]
        var sawNonZero = false, moved = false
        let start = world.state.units[slot].o.position.packed
        for _ in 0 ..< 200 {
            world.tick()
            if world.state.units[slot].spriteOffset > 0 { sawNonZero = true }
            if world.state.units[slot].o.position.packed != start { moved = true }
        }
        #expect(moved)  // it actually walked
        #expect(sawNonZero)  // and the walk cycle animated spriteOffset (was stuck at 0 before)
    }

    @Test("a trooper actually dies: the DIE branch (StartAnimation 0x04 → Die 0x0F) removes it")
    func trooperDies() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .closeAttack, unit1: .troopers, unit2: .tank, terrainSeed: 42))
        let victim = world.unitSlots[0]
        let victimType = world.state.units[victim].o.type
        world.state.units[victim].o.hitpoints = 1  // lethal in one hit (no downgrade)
        var removed = false
        for _ in 0 ..< 500 where !removed {
            world.tick()
            let u = world.state.units[victim]
            removed = !u.o.flags.contains(.used) || u.o.type != victimType
        }
        #expect(removed)  // DIE branch: Stop → RandomRange → VoicePlay → StartAnimation → Die → Unit_Remove
    }
}
