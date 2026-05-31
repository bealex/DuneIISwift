import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Scenario reinforcements — the `GameLoop_House` reinforcement block (`Simulation+Reinforcements`): a loaded
/// `[REINFORCEMENTS]` entry counts down and deploys at zero (an edge entry places the unit at a map edge; an
/// air entry flies it in on a carryall). 1.07 never repeats, so each entry fires exactly once.
@Suite("Reinforcements")
struct ReinforcementTests {
    // A synthetic unit script (so `unitScript`/`combat` exist and `setAction` resolves a default action).
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> Simulation {
        var s = GameState(); s.playerHouseID = 0; s.mapScale = 0
        _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 1)
        s.houses[0].unitCountMax = 100; s.houses[1].unitCountMax = 100
        return Simulation(state: s, scriptInfo: info)
    }

    private func setReinforcement(_ sim: inout Simulation, slot: Int, type: UnitType, house: UInt8,
                                  location: UInt8, timeLeft: UInt16) {
        var r = Reinforcement()
        r.unitType = UInt8(type.rawValue); r.houseID = house
        r.locationID = location; r.timeLeft = timeLeft; r.timeBetween = timeLeft
        sim.state.scenario.reinforcements[slot] = r
    }

    private func units(_ s: GameState, type: UnitType, house: UInt8) -> [Int] {
        s.units.indices.filter {
            s.units[$0].o.flags.contains(.used) && s.units[$0].o.type == UInt8(type.rawValue)
                && s.units[$0].o.houseID == house
        }
    }

    @Test("an edge reinforcement places the unit on the map and consumes the slot")
    func edgeDeploys() {
        var sim = base()
        setReinforcement(&sim, slot: 0, type: .trike, house: 0, location: 0 /* NORTH */, timeLeft: 1)

        sim.tickReinforcements()   // timeLeft 1 → 0 → deploy

        let trikes = units(sim.state, type: .trike, house: 0)
        #expect(trikes.count == 1)
        // Placed on the map (not off-map), and the entry is now empty (1.07 fires once).
        #expect(!sim.state.units[trikes[0]].o.flags.contains(.isNotOnMap))
        #expect(sim.state.scenario.reinforcements[0].isEmpty)
    }

    @Test("an air reinforcement flies the unit in on a carryall")
    func airDeploys() {
        var sim = base()
        // House 1 (non-player) skips the player-only map-validity retry loop in `findLocationTile`.
        setReinforcement(&sim, slot: 3, type: .trike, house: 1, location: 4 /* AIR */, timeLeft: 1)

        sim.tickReinforcements()

        let carryalls = sim.state.units.indices.filter {
            sim.state.units[$0].o.flags.contains(.used)
                && sim.state.units[$0].o.type == UInt8(UnitType.carryall.rawValue)
        }
        #expect(carryalls.count == 1)
        let carryall = carryalls[0]
        #expect(sim.state.units[carryall].o.flags.contains(.inTransport))
        let cargo = Int(sim.state.units[carryall].o.linkedID)
        #expect(cargo != 0xFF)
        #expect(sim.state.units[cargo].o.type == UInt8(UnitType.trike.rawValue))
        #expect(sim.state.scenario.reinforcements[3].isEmpty)
    }

    @Test("a reinforcement counts down over several cursor fires before deploying")
    func countsDown() {
        var sim = base()
        setReinforcement(&sim, slot: 0, type: .trike, house: 0, location: 1 /* EAST */, timeLeft: 3)

        sim.tickReinforcements(); #expect(sim.state.scenario.reinforcements[0].timeLeft == 2)
        sim.tickReinforcements(); #expect(sim.state.scenario.reinforcements[0].timeLeft == 1)
        #expect(units(sim.state, type: .trike, house: 0).isEmpty)   // not yet
        sim.tickReinforcements()                                     // 1 → 0 → deploy
        #expect(units(sim.state, type: .trike, house: 0).count == 1)
    }

    @Test("1.07 fires each reinforcement exactly once (no repeat)")
    func firesOnce() {
        var sim = base()
        setReinforcement(&sim, slot: 0, type: .trike, house: 0, location: 2 /* SOUTH */, timeLeft: 1)

        sim.tickReinforcements()   // deploys
        sim.tickReinforcements()   // empty slot — no second unit
        #expect(units(sim.state, type: .trike, house: 0).count == 1)
    }
}
