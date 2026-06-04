import DuneIIContracts
import DuneIIFormats
import DuneIIScenarios
import DuneIISimulation
import DuneIIWorld
import Foundation

// Headless test/oracle driver: loads the EMC scripts + ICON.MAP, builds the behavioural scenarios, and runs
// them deterministically with no renderer/input/audio — printing a concise event summary. A smoke-test of
// the live simulation (units + structures + the House loop). See Documentation/Architecture/ScenarioHarness.md.

func resourcesDir() -> URL? {
    let fm = FileManager.default
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    let candidates: [URL] = [
        CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) },
        cwd.appendingPathComponent("../Resources"),  // `swift run` from Code/
        cwd.appendingPathComponent("Resources"),
    ].compactMap { $0 }
    return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("Tiles/Maps/ICON.MAP").path) }
}

guard
    let res = resourcesDir(),
    let icon = try? Data(contentsOf: res.appendingPathComponent("Tiles/Maps/ICON.MAP")),
    let iconMap = try? IconMap(icon),
    let unitEmc = try? Data(contentsOf: res.appendingPathComponent("Scripts/UNIT/UNIT.emc")),
    let buildEmc = try? Data(contentsOf: res.appendingPathComponent("Scripts/BUILD/BUILD.emc")),
    let unitProgram = try? Emc.Program(unitEmc),
    let buildProgram = try? Emc.Program(buildEmc)
else {
    print("duneii-headless: Resources not found. Pass the Resources dir as argument 1, or run from Code/.")
    exit(1)
}

let builder = ScenarioBuilder(
    iconMap: iconMap,
    unitScript: ScriptInfo(unitProgram),
    structureScript: ScriptInfo(buildProgram)
)

func structureSummary(_ state: GameState) -> String {
    state.structures.indices.filter { state.structures[$0].o.flags.contains(.used) }.map { i in
        let s = state.structures[i]
        let max = StructureType(rawValue: Int(s.o.type)).map { StructureInfo[$0].o.hitpoints } ?? 0
        return "type \(s.o.type) hp \(s.o.hitpoints)/\(max) state \(s.state.rawValue)"
    }.joined(separator: ", ")
}

func runDemo(_ builder: ScenarioBuilder, _ kind: ScenarioKind, ticks: Int) {
    var world = builder.build(TestScenario(kind: kind, unit1: .tank, unit2: .tank, terrainSeed: 42))
    print("── \(kind.title) ──")
    print("  t0   structures: [\(structureSummary(world.state))]")

    var firstBullet = -1, destroyed = -1
    for t in 1 ... ticks {
        let before = world.state.structures.filter { $0.o.flags.contains(.used) }.count
        world.tick()
        if firstBullet < 0,
                world.state.units.contains(where: {
                    $0.o.flags.contains(.used) && $0.o.type == UInt8(UnitType.bullet.rawValue)
                }) {
            firstBullet = t
        }
        if destroyed < 0, world.state.structures.filter({ $0.o.flags.contains(.used) }).count < before { destroyed = t }
    }

    if firstBullet >= 0 { print("  first shot fired at tick \(firstBullet)") }
    if destroyed >= 0 { print("  a building was destroyed + removed at tick \(destroyed)") }
    print("  t\(ticks) structures: [\(structureSummary(world.state))]")
}

/// Print the tickStructure economy progression for a single tracked building (the structure of `type`):
/// its credits, build/repair countdown, HP, upgrade timer, and state at t0 → completion.
func runEconomyDemo(_ builder: ScenarioBuilder, _ kind: ScenarioKind, type: StructureType, ticks: Int) {
    var world = builder.build(TestScenario(kind: kind, unit1: .tank, unit2: .tank, terrainSeed: 42))

    func find() -> Structure? {
        world.state.structures.first { $0.o.flags.contains(.used) && $0.o.type == UInt8(type.rawValue) }
    }

    func line(_ label: String) {
        guard let s = find() else { return }

        let credits = world.state.houses[Int(HouseID.harkonnen.rawValue)].credits
        print(
            "  \(label) credits \(credits)  hp \(s.o.hitpoints)  countDown \(s.countDown)  "
                + "upgrade \(s.upgradeLevel)/\(s.upgradeTimeLeft)  state \(s.state.rawValue)"
        )
    }

    print("── \(kind.title) ──")
    line("t0  ")
    for _ in 1 ... ticks { world.tick() }
    line("t\(ticks)")
}

print("duneii-headless — behavioural demo (deterministic, headless: no renderer/input/audio)\n")
runDemo(builder, .attackStructure, ticks: 250)
runDemo(builder, .turretDefense, ticks: 300)
runEconomyDemo(builder, .factoryProduce, type: .lightVehicle, ticks: 250)
runEconomyDemo(builder, .repairBuilding, type: .windtrap, ticks: 300)
runEconomyDemo(builder, .upgradeBuilding, type: .barracks, ticks: 250)
print("\ndone.")
