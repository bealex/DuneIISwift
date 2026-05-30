import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import DuneIISimulation
@testable import DuneIIScenarios

/// **Tier-2a structure decision-trace** — the strongest structure-script parity check. The oracle's
/// `--parity-script-trace` + `--parity-script-structure=<index>` emits one line per executed opcode
/// (`pc/op/param/delay/SP/FP/return/current`) for one structure; we emit the identical line from
/// `StructureScriptRunner` via an injected `StructureScriptTracer`, then diff line-by-line. Unlike the
/// state golden (hp/state), this proves the EMC *execution* matches opcode-for-opcode — same PC path, same
/// stack discipline (`SP`/`FP` through subroutine calls), same decoded operands — and localizes any
/// divergence to the exact opcode. See `Documentation/Architecture/ScenarioHarness.md`.
///
/// Subject: the Ordos windtrap (structure index 0) of `attack-structure` — its placement animation (the
/// `Jump 0` shared subroutine, flexing `FP` 17↔14), `RemoveFogAroundTile`/`GetState`/`SetState`, and the
/// settle into `General_Delay(120)`. Fixture `attack-structure-struct0-trace.txt` is the oracle's trace.
@Suite("Structure decision-trace vs OpenDUNE (Tier-2a)")
struct StructureTraceTests {
    @Test("attack-structure windtrap (index 0): our per-opcode trace matches the oracle line-by-line")
    func windtrapTrace() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        let fix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let emc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
              let buildEmc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
              let ini = try? Data(contentsOf: fix.appendingPathComponent("attack-structure.ini")),
              let traceText = try? String(contentsOf: fix.appendingPathComponent("attack-structure-struct0-trace.txt"), encoding: .utf8)
        else { return }

        let expected = traceText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(!expected.isEmpty)

        let scriptInfo = ScriptInfo(try Emc.Program(emc))
        let structureScriptInfo = ScriptInfo(try Emc.Program(buildEmc))
        var state = GameState()
        state.loadScenario(ini: Ini(ini), iconMap: try IconMap(icon))
        state.viewportPosition = Tile32.packXY(x: 12, y: 12)

        // Scen-style prepare + the same attack order the golden uses (so the run is identical).
        let setup = UnitActions()
        for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
            setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: scriptInfo, in: &state)
            state.unitUpdateMap(1, slot)
        }
        UnitOrders(scriptInfo: scriptInfo).apply(.attack(unit: 22, tile: 1042), in: &state)

        // Trace structure index 0 (the windtrap) across the whole 400-tick run.
        let tracer = StructureScriptTracer(structureIndex: 0)
        var sim = Simulation(state: state, scriptInfo: scriptInfo,
                             structureScriptInfo: structureScriptInfo, structureTracer: tracer)
        for _ in 0 ..< 400 { sim.tick() }

        let ours = tracer.lines
        // First diverging line (if any) — reported with both sides for a localized failure.
        let firstDiff = (0 ..< min(ours.count, expected.count)).first { ours[$0] != expected[$0] }
        if let d = firstDiff {
            Issue.record("opcode trace diverges at line \(d):\n  ours    = \(ours[d])\n  oracle  = \(expected[d])")
        }
        #expect(firstDiff == nil)
        #expect(ours.count == expected.count, "trace length: ours \(ours.count) vs oracle \(expected.count)")
    }
}
