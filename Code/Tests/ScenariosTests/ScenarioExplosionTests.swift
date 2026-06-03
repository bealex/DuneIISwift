import DuneIIContracts
import DuneIIFormats
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIScenarios

/// End-to-end: destroying the windtrap in `attackStructure` starts an `EXPLOSION_STRUCTURE` (via the
/// `explode` native → `Map_MakeExplosion` → `explosionStart`), and the explosion **animates** (its
/// `spriteID` advances through the table) only when the lab opts into `tickExplosions`. With the gate
/// off (the golden/oracle-matched path) the explosion is started but never ticked.
@Suite("Scenario explosions")
struct ScenarioExplosionTests {
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

    /// Run `attackStructure` for 300 ticks, returning whether a structure explosion was ever started and
    /// the highest explosion `spriteID` seen across the run.
    private func run(tickExplosions: Bool) throws -> (started: Bool, maxSprite: Int)? {
        guard let builder = try loadBuilder() else { return nil }
        var world = builder.build(TestScenario(kind: .attackStructure, unit1: .tank, unit2: .tank, terrainSeed: 42))
        world.tickExplosions = tickExplosions
        var started = false, maxSprite = 0
        for _ in 0 ..< 300 {
            world.tick()
            for e in world.state.explosions where e.active {
                if e.tableIndex == ExplosionType.structure.rawValue { started = true }
                maxSprite = max(maxSprite, Int(e.spriteID))
            }
        }
        return (started, maxSprite)
    }

    @Test("lab (tickExplosions on): the building destruction starts + animates a structure explosion")
    func animatesWhenTicked() throws {
        guard let r = try run(tickExplosions: true) else { return }
        #expect(r.started)  // explosionStart fired from the explode native
        #expect(r.maxSprite >= 188)  // and it animated into the structure sprite range (188…192)
    }

    @Test("golden path (tickExplosions off): the explosion is started but never animates (spriteID stays 0)")
    func gatedOffDoesNotAnimate() throws {
        guard let r = try run(tickExplosions: false) else { return }
        #expect(r.started)  // still started (RNG-free, golden-neutral)
        #expect(r.maxSprite == 0)  // but never ticked → no sprite ever set
    }

    @Test("a killed unit actually dies: combat → ACTION_DIE → the DIE branch (0x0E→0x0F) removes it")
    func killedUnitIsRemoved() throws {
        guard let builder = try loadBuilder() else { return }
        var world = builder.build(TestScenario(kind: .closeAttack, unit1: .trike, unit2: .tank, terrainSeed: 42))
        world.tickExplosions = true
        let victim = world.unitSlots[0]  // the defender being attacked
        let victimType = world.state.units[victim].o.type
        world.state.units[victim].o.hitpoints = 1  // one salvo is lethal
        var removed = false
        for _ in 0 ..< 500 where !removed {
            world.tick()
            let u = world.state.units[victim]
            removed = !u.o.flags.contains(.used) || u.o.type != victimType  // freed (or the slot was reused)
        }
        #expect(removed)  // the DIE branch ran ExplosionSingle → DisplayDestroyedText → Die → Unit_Remove
    }
}
