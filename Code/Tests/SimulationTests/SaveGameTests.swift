import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Our native save format (`SaveGame`): a versioned binary encoding of the whole `GameState`. It captures
/// every mutable field — incl. both RNGs' internal state — so a loaded game **resumes bit-identically**:
/// continuing it produces the same run as the original (unlike a converted *original* save, which is only
/// behaviorally faithful).
@Suite("Save/load (our format)")
struct SaveGameTests {
    @Test("round-trips the GameState's fields + RNG state")
    func roundTripFields() throws {
        var s = GameState(random256Seed: 0x1234, randomLCGSeed: 0x5678)
        s.playerHouseID = 0; s.campaignID = 5; s.timerGame = 9999; s.gameSpeed = 3
        _ = s.houseAllocate(index: 0); s.houses[0].credits = 4242; s.houses[0].creditsStorage = 2000
        s.houses[0].unitCountMax = 100
        let u = s.unitAllocate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.trike.rawValue), houseID: 0)!
        s.units[u].o.position = Tile32.unpack(1234); s.units[u].o.hitpoints = 77; s.units[u].actionID = 5
        s.structureTick.palace = 4321
        for _ in 0 ..< 50 { _ = s.random256.next(); _ = s.randomLCG.next() }  // advance the RNGs past their seeds

        let loaded = try SaveGame.load(try SaveGame.save(s))
        #expect(loaded.timerGame == 9999)
        #expect(loaded.campaignID == 5)
        #expect(loaded.gameSpeed == 3)
        #expect(loaded.structureTick.palace == 4321)
        #expect(loaded.houses[0].credits == 4242)
        #expect(loaded.units[u].o.position.packed == 1234)
        #expect(loaded.units[u].o.hitpoints == 77)
        #expect(loaded.units[u].actionID == 5)
        // The RNG state round-trips exactly ⇒ the next draws agree.
        var origR = s.random256, gotR = loaded.random256
        #expect(origR.next() == gotR.next())
        var origL = s.randomLCG, gotL = loaded.randomLCG
        #expect(origL.next() == gotL.next())
    }

    @Test("rejects bad magic + an unsupported version")
    func errors() throws {
        #expect(throws: SaveGame.SaveError.self) { try SaveGame.load(Data([ 1, 2, 3 ])) }  // truncated
        #expect(throws: SaveGame.SaveError.self) { try SaveGame.load(Data([ 0, 0, 0, 0, 0, 0, 0 ])) }  // bad magic
        var good = try SaveGame.save(GameState())
        good[good.startIndex + 4] = 99  // corrupt the version byte
        #expect(throws: SaveGame.SaveError.self) { try SaveGame.load(good) }
    }

    @Test("a loaded mid-game scenario continues exactly like the original (deterministic resume)")
    func deterministicResume() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        guard
            let unitData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let buildData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
            let iconData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
            let iniData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scenarios/SCENA001.INI"))
        else { return }
        let unitInfo = ScriptInfo(try Emc.Program(unitData))
        let buildInfo = ScriptInfo(try Emc.Program(buildData))

        var state = GameState()
        state.loadScenario(ini: Ini(iniData), iconMap: try IconMap(iconData))
        state.viewportPosition = Tile32.packXY(x: 24, y: 24)
        let setup = UnitActions()
        for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
            setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: unitInfo, in: &state)
            state.unitUpdateMap(1, slot)
        }
        var sim = Simulation(state: state, scriptInfo: unitInfo, structureScriptInfo: buildInfo)
        for _ in 0 ..< 60 { sim.tick() }  // advance to a non-trivial mid-game state

        let data = try SaveGame.save(sim.state)
        let loaded = try SaveGame.load(data)
        #expect(loaded.iconMap != nil)  // the asset is saved, so the loaded game is self-contained

        // Continue both the original and the loaded copy from the same point; they must agree every tick.
        var loadedSim = Simulation(state: loaded, scriptInfo: unitInfo, structureScriptInfo: buildInfo)
        for t in 0 ..< 80 {
            sim.tick(); loadedSim.tick()
            #expect(digest(sim.state) == digest(loadedSim.state), "diverged at tick \(t)")
        }
    }

    /// A per-entity + RNG + clock digest that catches any state the save dropped.
    private func digest(_ s: GameState) -> [String] {
        let units = s.units.indices.filter { s.units[$0].o.flags.contains(.used) }.map {
            "u\(s.units[$0].o.index):\(s.units[$0].o.position.packed):\(s.units[$0].o.hitpoints):\(s.units[$0].actionID):\(s.units[$0].orientation[0].current)"
        }
        let structs = s.structures.indices.filter { s.structures[$0].o.flags.contains(.used) }.map {
            "s\(s.structures[$0].o.index):\(s.structures[$0].o.hitpoints):\(s.structures[$0].state.rawValue):\(s.structures[$0].countDown)"
        }
        let houses = s.houses.indices.filter { s.houses[$0].flags.contains(.used) }.map {
            "h\(s.houses[$0].index):\(s.houses[$0].credits):\(s.houses[$0].powerProduction)"
        }
        return [ "t\(s.timerGame)", "r\(s.random256.rawState)", "l\(s.randomLCG.rawState)" ]
            + units.sorted() + structs.sorted() + houses.sorted()
    }
}
