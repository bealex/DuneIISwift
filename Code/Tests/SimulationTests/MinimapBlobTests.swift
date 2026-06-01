import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// The minimap's top-left "corner blob": a unit/structure plotted in the **unplayable border** (tile (0,0)
/// for the default map scale). Units *can* legitimately sit there — the Atreides palace Fremen wave scatters
/// (`Tile_MoveByRandom`) into the border, and OpenDUNE creates it anyway (the `Unit_Create` is wrapped in
/// `g_validateStrictIfZero++`, bypassing the position check) — so this is faithful sim, not a spawn bug. The
/// fix is presentation-only: the minimap plots a blip only when its tile is inside the playable rectangle
/// (`frame.mapArea`), the same clip the base terrain image uses. These tests load a real scenario, run it,
/// and check that predicate — `SCENO020` reproduces the border spawn; `SCENA020` is the requested scenario.
@Suite("Minimap corner blob — playable-area clip")
struct MinimapBlobTests {
    private func repoRoot() -> URL {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/SimulationTests → repo root
        return repo
    }

    /// Run `scenario` for `ticks` and, per tick, partition what the minimap would consider drawing into
    /// `drawn` (tile inside `mapArea` — what the fixed minimap plots) and `clipped` (in the unplayable
    /// border). An item is `"<kind> <type> tile=(x,y)"`.
    private func run(scenario name: String, ticks: Int) throws -> (drawn: Set<String>, clipped: Set<String>)? {
        let repo = repoRoot()
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let unitEmc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
              let buildEmc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
              let teamEmc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/TEAM/TEAM.emc")),
              let iniData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scenarios/\(name)"))
        else { return nil }   // install assets absent — skip

        let scriptInfo = ScriptInfo(try Emc.Program(unitEmc))
        let structureScriptInfo = ScriptInfo(try Emc.Program(buildEmc))
        let teamScriptInfo = ScriptInfo(try Emc.Program(teamEmc))
        let ini = Ini(iniData)

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: try IconMap(icon), teamScriptOffsets: teamScriptInfo.offsets)
        let player = playerHouse(ini) ?? .atreides
        state.playerHouseID = UInt8(player.rawValue)
        for h in 0 ..< 6 { _ = state.houseAllocate(index: UInt8(h)); if state.houses[h].unitCountMax == 0 { state.houses[h].unitCountMax = 39 } }
        state.houses[Int(player.rawValue)].flags.insert(.human)
        state.viewportPosition = Tile32.packXY(x: 32, y: 32)

        let setup = UnitActions()
        for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
            setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: scriptInfo, in: &state)
            state.unitUpdateMap(1, slot)
        }

        var sim = Simulation(state: state, scriptInfo: scriptInfo, structureScriptInfo: structureScriptInfo,
                             teamScriptInfo: teamScriptInfo, tickExplosions: true, tickAnimations: true)
        var drawn = Set<String>(), clipped = Set<String>()
        for t in 0 ... ticks {
            if t > 0 { sim.tick() }
            let f = sim.makeFrameInfo()
            let area = f.mapArea
            func note(_ kind: String, _ type: String, _ px: Int, _ py: Int) {
                let tx = px / 256, ty = py / 256
                let item = "\(kind) \(type) tile=(\(tx),\(ty))"
                if area.contains(tileX: tx, tileY: ty) { drawn.insert(item) } else { clipped.insert(item) }
            }
            for u in f.units { note("UNIT", "\(u.type)", u.positionX, u.positionY) }
            for s in f.structures { note("STRUCT", "\(s.type)", s.positionX, s.positionY) }
        }
        return (drawn, clipped)
    }

    /// Whatever the minimap *draws* must be inside the playable rectangle — never a border/corner tile.
    private func assertNoBorderBlip(_ r: (drawn: Set<String>, clipped: Set<String>), _ scenario: String) {
        let bordered = r.drawn.filter { $0.hasSuffix("tile=(0,0)") }
        #expect(bordered.isEmpty, "\(scenario): minimap would draw a (0,0)-corner blip: \(bordered)")
    }

    @Test("SCENO020: the Fremen palace wave can land in the border, and the minimap clips it")
    func reproducerClipped() throws {
        guard let r = try run(scenario: "SCENO020.INI", ticks: 1500) else { return }
        // The border spawn really happens (the corner blob's source) — and it lands in the clipped set, so the
        // fixed minimap never plots it.
        #expect(r.clipped.contains { $0.hasSuffix("tile=(0,0)") },
                "expected a unit to spawn in the unplayable corner (the Fremen palace wave) — none did")
        assertNoBorderBlip(r, "SCENO020")
    }

    @Test("SCENA020 (Atreides): the minimap never plots a corner blip over a run")
    func requestedScenario() throws {
        guard let r = try run(scenario: "SCENA020.INI", ticks: 1500) else { return }
        assertNoBorderBlip(r, "SCENA020")
    }

    /// The host's player-house lookup (`AssetStore.playerHouse`) — the `Brain=Human` house.
    private func playerHouse(_ ini: Ini) -> HouseID? {
        for h in HouseID.allCases where ini.string(section: h.displayName, key: "Brain")?.caseInsensitiveCompare("Human") == .orderedSame { return h }
        return nil
    }
}
