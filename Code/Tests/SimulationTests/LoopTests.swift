import Testing
import DuneIIWorld
@testable import DuneIISimulation

/// Tests for the Phase-3 loop foundation: the two-clock model, pause, game speed, and the
/// `GameLoop_Unit` cadence cursors. The per-unit state-machine work is ported in later slices.
@Suite("Simulation loop")
struct LoopTests {
    @Test("tick advances both clocks")
    func clocks() {
        var sim = Simulation()
        sim.tick()
        #expect(sim.state.timerGame == 1)
        #expect(sim.state.timerGUI == 1)
        sim.tick()
        #expect(sim.state.timerGame == 2)
        #expect(sim.state.timerGUI == 2)
    }

    @Test("pause freezes the game clock + phases, GUI clock keeps running")
    func pause() {
        var sim = Simulation()
        sim.state.paused = true
        sim.tick()
        sim.tick()
        #expect(sim.state.timerGUI == 2)
        #expect(sim.state.timerGame == 0)
        #expect(sim.state.unitTick.movement == 0)   // the unit phase never ran
    }

    @Test("unit cadence fires on the right ticks and advances its cursors")
    func unitCadence() {
        var sim = Simulation()   // gameSpeed 2 (normal)

        sim.state.timerGame = 1
        let f1 = sim.advanceUnitCadence()
        #expect(f1 == [.movement, .rotation, .blinking, .unknown4, .script, .unknown5, .deviation])
        #expect(sim.state.unitTick.movement == 4)    // 1 + 3
        #expect(sim.state.unitTick.rotation == 5)     // 1 + AdjustToGameSpeed(4,2,8,inverse)@speed2 = 1 + 4
        #expect(sim.state.unitTick.script == 6)       // 1 + 5
        #expect(sim.state.unitTick.deviation == 61)   // 1 + 60

        sim.state.timerGame = 2
        #expect(sim.advanceUnitCadence() == [])       // nothing due at tick 2

        sim.state.timerGame = 4
        let f4 = sim.advanceUnitCadence()
        #expect(f4.contains(.movement))               // cursor 4 <= 4
        #expect(f4.contains(.blinking))               // cursor 4 <= 4
        #expect(!f4.contains(.rotation))              // cursor 5 > 4
        #expect(!f4.contains(.script))                // cursor 6 > 4
        #expect(sim.state.unitTick.movement == 7)     // 4 + 3
    }

    @Test("rotation interval scales with game speed")
    func rotationSpeed() {
        for (speed, expectedInterval) in [(UInt16(0), UInt32(8)), (2, 4), (4, 2)] {
            var sim = Simulation()
            sim.state.gameSpeed = speed
            sim.state.timerGame = 1
            _ = sim.advanceUnitCadence()
            #expect(sim.state.unitTick.rotation == 1 + expectedInterval)
        }
    }

    @Test("adjustToGameSpeed wrapper feeds the run's gameSpeed")
    func adjust() {
        var sim = Simulation()
        sim.state.gameSpeed = 4
        #expect(sim.adjustToGameSpeed(normal: 4, minimum: 2, maximum: 8, inverse: true)
                == Tools.adjustToGameSpeed(normal: 4, minimum: 2, maximum: 8, inverseSpeed: true, gameSpeed: 4))
    }
}
