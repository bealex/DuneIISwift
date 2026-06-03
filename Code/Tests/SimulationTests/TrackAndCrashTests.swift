import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Two visual-effect behaviours driven through the live `Simulation` under the real `UNIT.EMC`:
///   1. a **tracked** unit (tank) leaves **sand tracks** as it drives over sand (`Unit_Move` →
///      `Animation_Start(g_table_animation_unitMove)`, the "Sand Tracks" icon group);
///   2. a destroyed **ornithopter** spawns its **death-explosion cluster** — the faithful 1.07 "crash"
///      (its `ACTION_DIE` script runs `Unit_ExplosionMultiple` → eight `DEATH_HAND` explosions).
///
/// (The dedicated `EXPLOSION_ORNITHOPTER_CRASH` wreck — icon group "Flying-Machine Crash" — exists in
/// OpenDUNE's tables but is **never triggered in 1.07**, so it is intentionally not produced.)
///
/// These are animation/explosion effects, ticked off the cross-engine golden path (they draw RNG, which the
/// oracle scenario harness doesn't), so they're standalone behavioural tests, not goldens. Short-circuit if
/// the committed scripts/assets are absent.
@Suite("Sand tracks + ornithopter crash")
struct TrackAndCrashTests {
    private struct Assets { let unit: ScriptInfo; let build: ScriptInfo; let iconMap: IconMap }

    private func load() -> Assets? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/SimulationTests → repo
        guard
            let unitData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let buildData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
            let iconData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
            let unit = try? Emc.Program(unitData),
            let build = try? Emc.Program(buildData),
            let iconMap = try? IconMap(iconData)
        else { return nil }
        return Assets(unit: ScriptInfo(unit), build: ScriptInfo(build), iconMap: iconMap)
    }

    /// A house-0 game on an all-sand, fully-revealed map (sand/dune is where tracks are laid).
    private func sandWorld(_ a: Assets) -> GameState {
        var state = GameState()
        state.playerHouseID = 0
        _ = state.houseAllocate(index: 0)
        state.houses[0].unitCountMax = 100
        state.houses[0].credits = 1000
        state.tileIDs = TileIDs(iconMap: a.iconMap) ?? TileIDs()
        state.iconMap = a.iconMap
        state.mapScale = 0
        let sand = state.tileIDs.landscape  // landscapeSpriteMap[0] == normalSand
        for i in 0 ..< state.map.count {
            state.map[i].groundTileID = sand
            state.map[i].isUnveiled = true
            state.map[i].overlayTileID = 0
        }
        return state
    }

    @Test("a tracked unit (tank) leaves sand-track overlays as it drives over sand", .timeLimit(.minutes(1)))
    func sandTracks() throws {
        guard let a = load() else { return }
        var state = sandWorld(a)

        // A combat tank (tracked) at (20,20), ordered to drive far east across the sand.
        let tank = state.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        state.units[tank].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        state.units[tank].o.hitpoints = UnitInfo[.tank].o.hitpoints
        state.unitUpdateMap(1, tank)

        var sim = Simulation(state: state, scriptInfo: a.unit, structureScriptInfo: a.build, tickAnimations: true)
        UnitOrders(scriptInfo: a.unit).apply(
            .move(unit: UInt16(tank), tile: Tile32.packXY(x: 45, y: 20)),
            in: &sim.state
        )

        // The track overlays come from the "Sand Tracks" icon group (5).
        let trackTiles = Set((sim.state.iconMap?.group(5)?.tileIDs ?? []).map { UInt8(truncatingIfNeeded: $0) })
        #expect(!trackTiles.isEmpty, "ICON.MAP has no Sand Tracks group")

        var trackCount = 0
        for _ in 0 ..< 600 {
            sim.tick()
            trackCount = sim.state.map.indices.filter { trackTiles.contains(sim.state.map[$0].overlayTileID) }.count
            if trackCount > 0 { break }
        }
        #expect(trackCount > 0, "the tank never left a sand-track overlay while driving over sand")
    }

    @Test(
        "a destroyed ornithopter shows the crash wreck (EXPLOSION_ORNITHOPTER_CRASH → map animation)",
        .timeLimit(.minutes(1))
    )
    func ornithopterCrash() throws {
        guard let a = load() else { return }
        var state = sandWorld(a)

        // An ornithopter mid-map, sent to its death (the path a shot-down winger takes: hp 0 → ACTION_DIE).
        let orni = state.unitAllocate(index: 0, type: UInt8(UnitType.ornithopter.rawValue), houseID: 0)!
        state.units[orni].o.position = Tile32.unpack(Tile32.packXY(x: 32, y: 32))
        state.units[orni].o.hitpoints = UnitInfo[.ornithopter].o.hitpoints
        state.unitUpdateMap(1, orni)
        UnitActions().setAction(slot: orni, action: UInt8(ActionType.die.rawValue), scriptInfo: a.unit, in: &state)

        // Tick both explosions and animations: the death script fires `Unit_ExplosionSingle(16)` (the crash
        // explosion), whose `SET_ANIMATION 0` starts the "Flying-Machine Crash" map animation (icon group 3).
        var sim = Simulation(
            state: state,
            scriptInfo: a.unit,
            structureScriptInfo: a.build,
            tickExplosions: true,
            tickAnimations: true
        )

        let wreckTiles = Set((sim.state.iconMap?.group(3)?.tileIDs ?? []).map { UInt8(truncatingIfNeeded: $0) })
        #expect(!wreckTiles.isEmpty, "ICON.MAP has no Flying-Machine Crash group")

        var sawCrashExplosion = false
        var sawWreck = false
        for _ in 0 ..< 3000 {
            sim.tick()
            if sim.state.explosions.contains(where: {
                $0.active && $0.tableIndex == ExplosionType.ornithopterCrash.rawValue
            }) {
                sawCrashExplosion = true
            }
            if sim.state.map.indices.contains(where: { wreckTiles.contains(sim.state.map[$0].overlayTileID) }) {
                sawWreck = true; break
            }
        }
        #expect(sawCrashExplosion, "the ornithopter death never created the EXPLOSION_ORNITHOPTER_CRASH explosion")
        #expect(sawWreck, "the ornithopter crash never painted the Flying-Machine Crash wreck overlay")
    }
}
