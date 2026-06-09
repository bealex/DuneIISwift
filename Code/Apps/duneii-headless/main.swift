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

// `duneii-headless profile [SCENARIO.INI] [ticks]` — load a heavy late-game scenario through the full live
// simulation (all six houses, unit + structure + team scripts, animations + explosions on) and report a
// per-tick / per-phase wall-clock breakdown so bottlenecks are visible. See Documentation/Architecture/Profiling.md.
if CommandLine.arguments.dropFirst().contains("profile") {
    let extras = CommandLine.arguments.dropFirst().filter { $0 != "profile" && $0 != res.path }
    let scenarioName = extras.first(where: { $0.uppercased().hasSuffix(".INI") }) ?? "SCENH022.INI"
    let ticks = extras.compactMap { Int($0) }.first ?? 2000
    profile(
        res: res,
        iconMap: iconMap,
        unitProgram: unitProgram,
        buildProgram: buildProgram,
        scenario: scenarioName,
        ticks: ticks
    )
    exit(0)
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

/// Load a real campaign scenario into a full live `Simulation` (mirrors `GameModel.load` / the parity
/// harness setup), warm it up, then time `ticks` profiled ticks and print a per-phase breakdown.
func profile(
    res: URL,
    iconMap: IconMap,
    unitProgram: Emc.Program,
    buildProgram: Emc.Program,
    scenario name: String,
    ticks: Int
) {
    guard
        let iniData = try? Data(contentsOf: res.appendingPathComponent("Scenarios/\(name)")),
        let teamEmc = try? Data(contentsOf: res.appendingPathComponent("Scripts/TEAM/TEAM.emc")),
        let teamProgram = try? Emc.Program(teamEmc)
    else {
        print("profile: scenario \(name) or TEAM.emc not found under \(res.path)")
        return
    }

    let unitScript = ScriptInfo(unitProgram)
    let structureScript = ScriptInfo(buildProgram)
    let teamScript = ScriptInfo(teamProgram)
    let ini = Ini(iniData)

    var state = GameState()
    // `activateTeamHousesAI: true` — wake every AI house at load so the scenario is busy from tick 0 (the
    // profiling goal is a heavy, fully-active tick; the live client defers this for faithfulness).
    state.loadScenario(ini: ini, iconMap: iconMap, teamScriptOffsets: teamScript.offsets, activateTeamHousesAI: true)
    let player = state.houses.first(where: { $0.flags.contains(.used) }).map { Int($0.index) } ?? 0
    state.playerHouseID = UInt8(player)
    for h in 0 ..< 6 {
        _ = state.houseAllocate(index: UInt8(h))
        if state.houses[h].unitCountMax == 0 { state.houses[h].unitCountMax = 39 }
    }
    state.houses[player].flags.insert(.human)
    state.viewportPosition = Tile32.packXY(x: 32, y: 32)

    let setup = UnitActions()
    for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
        setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: unitScript, in: &state)
        state.unitUpdateMap(1, slot)
    }

    var sim = Simulation(
        state: state,
        scriptInfo: unitScript,
        structureScriptInfo: structureScript,
        teamScriptInfo: teamScript,
        tickExplosions: true,
        tickAnimations: true
    )

    func counts(_ state: GameState) -> (units: Int, structures: Int, bullets: Int) {
        var units = 0, structures = 0, bullets = 0
        for unit in state.units where unit.o.flags.contains(.used) {
            if unit.o.type == UInt8(UnitType.bullet.rawValue) { bullets += 1 } else { units += 1 }
        }
        for structure in state.structures where structure.o.flags.contains(.used) { structures += 1 }
        return (units, structures, bullets)
    }

    let initial = counts(sim.state)
    let activeHouses = sim.state.houses.filter { $0.flags.contains(.used) && $0.flags.contains(.isAIActive) }.count
    print("duneii-headless — profile (heavy scenario, deterministic, no renderer/input/audio)\n")
    print("  scenario \(name)  units \(initial.units)  structures \(initial.structures)  AI-active houses \(activeHouses)")

    let warmup = min(200, ticks / 4)
    for _ in 0 ..< warmup { sim.tick() }
    print("  warmed up \(warmup) ticks; profiling \(ticks) ticks…\n")

    var totals = PhaseTimings()
    var peak = counts(sim.state)
    for _ in 0 ..< ticks {
        totals += sim.tickProfiled()
        let live = counts(sim.state)
        peak = (max(peak.units, live.units), max(peak.structures, live.structures), max(peak.bullets, live.bullets))
    }

    let n = Double(max(totals.ticks, 1))
    let msPerTick = totals.total / n * 1000

    func phaseRow(_ label: String, _ secs: Double) {
        let milli = secs / n * 1000
        let percent = totals.total > 0 ? secs / totals.total * 100 : 0
        let padded = label.padding(toLength: 10, withPad: " ", startingAt: 0)
        print("  \(padded)" + String(format: "%8.4f ms  %5.1f%%", milli, percent))
    }

    print(
        String(
            format: "  %.4f ms/tick   %.0f ticks/s   (%d ticks profiled)\n",
            msPerTick,
            n / totals.total,
            totals.ticks
        )
    )
    print("  phase        ms/tick      %")
    phaseRow("team", totals.team)
    phaseRow("unit", totals.unit)
    phaseRow("structure", totals.structure)
    phaseRow("house", totals.house)
    phaseRow("other", totals.other)
    print(
        String(
            format: "\n  peak entities: units %d, structures %d, bullets %d",
            peak.units,
            peak.structures,
            peak.bullets
        )
    )
}

print("duneii-headless — behavioural demo (deterministic, headless: no renderer/input/audio)\n")
runDemo(builder, .attackStructure, ticks: 250)
runDemo(builder, .turretDefense, ticks: 300)
runEconomyDemo(builder, .factoryProduce, type: .lightVehicle, ticks: 250)
runEconomyDemo(builder, .repairBuilding, type: .windtrap, ticks: 300)
runEconomyDemo(builder, .upgradeBuilding, type: .barracks, ticks: 250)
print("\ndone.")
