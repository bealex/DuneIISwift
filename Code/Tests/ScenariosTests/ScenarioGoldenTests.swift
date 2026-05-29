import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import DuneIISimulation
@testable import DuneIIScenarios

/// Per-scenario golden vs OpenDUNE — the **whole-run, per-tick** comparison framework. Both engines load
/// the shared `bootstrap.ini`, apply the same simulated command stream, and produce a per-tick sequence
/// of per-unit states; this asserts ours equals the oracle's, tick by tick.
///
/// The oracle fixtures come from the `--parity-scenario` mode (see `Documentation/Architecture/
/// ScenarioHarness.md`), e.g.:
///   opendune --parity-scenario=99 --parity-cmd=move,22,2600 --parity-ticks=N --parity-data-dir=<dir> --parity-dump=moving-golden.jsonl
///
/// **`comparedTicks`** gates how many leading ticks are asserted (1 = frame 0 only). It's 1 today
/// because: (a) our `GameLoop_Unit` doesn't run unit scripts/movement yet (that's the next phase), and
/// (b) the OpenDUNE oracle's movement/placement path (`Unit_UpdateMap`/`Game_Prepare`) doesn't run in
/// this headless sandbox, so the committed fixtures only carry frame 0. Raise `comparedTicks` and
/// regenerate the fixture with `--parity-ticks=N` (in a display-capable env) as the natives land — the
/// run + comparison loop below already handles the full trajectory.
@Suite("Scenario golden vs OpenDUNE")
struct ScenarioGoldenTests {
    struct Frame: Decodable { let tick: Int; let units: [UnitState] }
    struct UnitState: Decodable, Equatable {
        let index: UInt16; let type: UInt8; let houseID: UInt8; let packed: UInt16; let orient: Int16
        let hp: UInt16; let actionID: UInt8; let targetMove: UInt16; let targetAttack: UInt16; let alive: Int
    }

    private func snapshot(_ s: GameState) -> [UnitState] {
        s.units.indices.filter { s.units[$0].o.flags.contains(.used) }.map { i in
            let u = s.units[i]
            return UnitState(index: u.o.index, type: u.o.type, houseID: u.o.houseID,
                             packed: u.o.position.packed, orient: Int16(u.orientation[0].current),
                             hp: u.o.hitpoints, actionID: u.actionID, targetMove: u.targetMove,
                             targetAttack: u.targetAttack, alive: u.o.flags.contains(.used) ? 1 : 0)
        }
    }

    @Test("moving: per-tick run matches the oracle (frame 0 today; the loop handles the full trajectory)")
    func moving() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        let fix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let emc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
              let ini = try? Data(contentsOf: fix.appendingPathComponent("bootstrap.ini")),
              let golden = try? String(contentsOf: fix.appendingPathComponent("moving-golden.jsonl"), encoding: .utf8)
        else { return }

        // Oracle trajectory (one frame per tick), and our matching run.
        let oracle = golden.split(separator: "\n").map { try! JSONDecoder().decode(Frame.self, from: Data($0.utf8)) }
        #expect(!oracle.isEmpty)

        var state = GameState()
        state.loadScenario(ini: Ini(ini), iconMap: try IconMap(icon))
        let tank = state.units.first { $0.o.flags.contains(.used) }!
        UnitOrders(scriptInfo: ScriptInfo(try Emc.Program(emc))).apply(.move(unit: tank.o.index, tile: 2600), in: &state)

        // Run our engine for the whole trajectory, capturing a frame per tick (frame 0 = post-command).
        var sim = Simulation(state: state)
        var ours: [[UnitState]] = [snapshot(sim.state)]
        for _ in 1 ..< max(oracle.count, 1) {
            sim.tick()
            ours.append(snapshot(sim.state))
        }

        // Assert the leading `comparedTicks` frames match the oracle, tick by tick.
        let comparedTicks = 1
        for t in 0 ..< min(comparedTicks, oracle.count, ours.count) {
            #expect(oracle[t].tick == t)
            #expect(ours[t] == oracle[t].units, "tick \(t) mismatch")
        }
    }
}
