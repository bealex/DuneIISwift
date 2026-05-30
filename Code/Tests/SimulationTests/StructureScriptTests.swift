import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Real-data integration for the structure script subsystem: bridge the committed `BUILD.EMC` into a
/// `ScriptInfo`, place a structure, and drive `Simulation.tick()` so `GameLoop_Structure` loads + runs its
/// EMC script. Covers (a) a healthy structure idling without being removed, and (b) the death path —
/// damaging a structure to 0 HP → its reloaded death script runs Explode→Delay→Destroy → `Structure_Remove`
/// frees the slot, drops it from the find array, and clears the tile occupancy. Plus focused decision-trace
/// coverage of the state natives. See `Documentation/Algorithms/StructureScript.md`.
@Suite("Structure scripts (BUILD.EMC under the VM)")
struct StructureScriptTests {
    private func emc(_ relative: String) -> ScriptInfo? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/SimulationTests → repo root
        guard let data = try? Data(contentsOf: repo.appendingPathComponent(relative)),
              let program = try? Emc.Program(data) else { return nil }
        return ScriptInfo(program)
    }

    /// A `Simulation` with both EMCs bridged and a single `windtrap` placed for `house`, HP 200, idle. The
    /// structure's 2×2 tile occupancy is stamped manually (no `iconMap` needed for the script path).
    private func setup(house: UInt8 = 0, player: UInt8 = 0) -> (Simulation, Int, [Int])? {
        guard let unit = emc("Resources/Scripts/UNIT/UNIT.emc"),
              let build = emc("Resources/Scripts/BUILD/BUILD.emc") else { return nil }

        var s = GameState(random256Seed: 0x51234)
        s.playerHouseID = player
        _ = s.houseAllocate(index: house)
        s.houses[Int(house)].unitCountMax = 100

        let slot = s.structureAllocate(index: Pool.structureIndexInvalid,
                                       type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.position = Tile32.unpack(20 * 64 + 20)
        s.structures[slot].state = .idle
        s.structures[slot].o.hitpoints = 200

        // Stamp the structure's tile occupancy (the bit of `structureUpdateMap` that doesn't need an
        // iconMap): `hasStructure` plus the 1-based pool `index`, so a fog reveal / pool query that hits the
        // building's own tiles resolves the slot rather than reading a 0 index.
        let layout = StructureLayoutInfo[StructureInfo[.windtrap].layout]
        let base = Int(s.structures[slot].o.position.packed)
        var tiles: [Int] = []
        for i in 0 ..< Int(layout.tileCount) {
            let p = base + Int(layout.tiles[i])
            s.map[p].hasStructure = true
            s.map[p].index = UInt8(truncatingIfNeeded: slot + 1)
            s.map[p].houseID = house
            tiles.append(p)
        }

        let sim = Simulation(state: s, scriptInfo: unit, structureScriptInfo: build)
        return (sim, slot, tiles)
    }

    private func structureSlots(_ s: GameState) -> [Int] {
        var s = s, find = PoolFind(), slots: [Int] = []
        while let slot = s.structureFind(&find) { slots.append(slot) }
        return slots
    }

    @Test("BUILD.EMC bridges + a healthy structure's script loads and idles without removing it")
    func healthyIdles() throws {
        guard var (sim, slot, _) = setup() else { return }   // short-circuit if the scripts are absent

        // One game tick past the first structure-script tick loads the type's script.
        for _ in 0 ..< 6 { sim.tick() }
        #expect(sim.structureScript != nil)

        // Idle for a while: a healthy windtrap is never destroyed, and the death flag stays clear.
        for _ in 0 ..< 200 { sim.tick() }
        #expect(sim.state.structures[slot].o.flags.contains(.used))
        #expect(sim.state.structures[slot].o.hitpoints == 200)
        #expect(sim.state.structures[slot].o.script.variables[0] == 0)
        #expect(structureSlots(sim.state).contains(slot))
    }

    @Test("damaging a structure to 0 HP runs the death script → Structure_Remove (slot freed, tiles cleared)")
    func deathPathRemovesStructure() throws {
        guard var (sim, slot, tiles) = setup(house: 1, player: 0) else { return }   // enemy windtrap

        // Lethal damage begins destruction: death flag set, but the slot is not yet freed (the death
        // script, driven by GameLoop_Structure, removes it).
        let destroyed = sim.state.structureDamage(slot, damage: 500, range: 0)
        #expect(destroyed)
        #expect(sim.state.structures[slot].o.script.variables[0] == 1)
        #expect(sim.state.structures[slot].o.flags.contains(.used))

        // Drive the loop: the reloaded death script runs Explode → Delay → Destroy → Structure_Remove.
        var removed = false
        for _ in 0 ..< 3000 where !removed {
            sim.tick()
            removed = !sim.state.structures[slot].o.flags.contains(.used)
        }
        #expect(removed)
        #expect(!structureSlots(sim.state).contains(slot))           // dropped from the find array
        for p in tiles { #expect(!sim.state.map[p].hasStructure) }   // tile occupancy cleared
    }

    @Test("Script_Structure_SetState resolves DETECT, GetState reports it")
    func setStateDetect() throws {
        guard var (sim, slot, _) = setup() else { return }
        let combat = sim.unitScript!.combat
        let fns = StructureScriptFunctions(combat: combat)

        // DETECT with no linked unit → IDLE.
        sim.state.structures[slot].o.linkedID = 0xFF
        _ = fns.setState(slot: slot, state: StructureState.detect.rawValue, in: &sim.state)
        #expect(sim.state.structures[slot].state == .idle)
        #expect(fns.getState(slot: slot, in: sim.state) == UInt16(bitPattern: StructureState.idle.rawValue))

        // DETECT with a linked unit + a running countdown → BUSY.
        sim.state.structures[slot].o.linkedID = 3
        sim.state.structures[slot].countDown = 50
        _ = fns.setState(slot: slot, state: StructureState.detect.rawValue, in: &sim.state)
        #expect(sim.state.structures[slot].state == .busy)

        // DETECT with a linked unit + countdown elapsed → READY.
        sim.state.structures[slot].countDown = 0
        _ = fns.setState(slot: slot, state: StructureState.detect.rawValue, in: &sim.state)
        #expect(sim.state.structures[slot].state == .ready)
    }
}
