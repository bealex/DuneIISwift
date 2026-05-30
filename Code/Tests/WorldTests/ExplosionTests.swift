import Testing
@testable import DuneIIWorld

/// The explosion subsystem (`GameState+Explosion.swift`) — a port of OpenDUNE `src/explosion.c`.
/// `explosionStart` is RNG-free; `explosionTick` walks the command table one step per due tick.
@Suite("Explosion subsystem")
struct ExplosionTests {
    /// Step the explosion pass one command: advance the GUI clock past the due time and tick once.
    /// (`explosionTimer` is reset to 0 each step so the gate always opens — the real loop tracks the
    /// soonest due time, which we exercise separately.)
    private func step(_ state: inout GameState) {
        state.timerGUI &+= 1000
        state.explosionTimer = 0
        state.explosionTick()
    }

    @Test("explosionStart fills the first free slot, flags the tile, and draws no RNG")
    func startNoRNG() {
        var state = GameState(random256Seed: 7, randomLCGSeed: 7)
        // The RNGs are value types and not Equatable, so compare them by their next output instead.
        var lcgBefore = state.randomLCG
        var r256Before = state.random256
        let pos = Tile32.unpack(Tile32.packXY(x: 5, y: 6))

        state.explosionStart(type: ExplosionType.impactSmall.rawValue, position: pos)

        let slot = try! #require(state.explosions.firstIndex { $0.active })
        #expect(state.explosions[slot].tableIndex == ExplosionType.impactSmall.rawValue)
        #expect(state.explosions[slot].position.packed == pos.packed)
        #expect(state.map[Int(pos.packed)].hasExplosion)
        // No RNG drawn by Start (golden-neutral): both streams still yield their original next value.
        var lcgAfter = state.randomLCG
        var r256After = state.random256
        #expect(lcgAfter.next() == lcgBefore.next())
        #expect(r256After.next() == r256Before.next())
    }

    @Test("impactSmall runs 153 → 153 → STOP, then frees the slot and clears the tile")
    func impactSmallSequence() {
        var state = GameState()
        let pos = Tile32.unpack(Tile32.packXY(x: 4, y: 4))
        state.explosionStart(type: ExplosionType.impactSmall.rawValue, position: pos)
        let slot = try! #require(state.explosions.firstIndex { $0.active })

        // [setSprite 153, setTimeout 3, bloom 0, setSprite 153, setTimeout 3, stop]
        step(&state); #expect(state.explosions[slot].spriteID == 153)   // setSprite 153
        step(&state)                                                    // setTimeout 3
        step(&state)                                                    // bloom (seam)
        step(&state); #expect(state.explosions[slot].spriteID == 153)   // setSprite 153
        step(&state)                                                    // setTimeout 3
        step(&state)                                                    // stop
        #expect(!state.explosions[slot].active)
        #expect(!state.map[Int(pos.packed)].hasExplosion)
    }

    @Test("structure explosion: SET_RANDOM_TIMEOUT draws the LCG, then cycles sprites 188 → 192")
    func structureSequence() {
        var state = GameState(random256Seed: 1, randomLCGSeed: 1)
        var r256Before = state.random256
        let pos = Tile32.unpack(Tile32.packXY(x: 8, y: 8))
        state.explosionStart(type: ExplosionType.structure.rawValue, position: pos)
        let slot = try! #require(state.explosions.firstIndex { $0.active })

        var lcgBefore = state.randomLCG
        step(&state)                                                    // setRandomTimeout 60 → one LCG draw
        var lcgAfter = state.randomLCG
        var r256After = state.random256
        #expect(lcgAfter.next() != lcgBefore.next())                    // LCG advanced (one draw)
        #expect(r256After.next() == r256Before.next())                  // but the 256-RNG is untouched

        step(&state); #expect(state.explosions[slot].spriteID == 188)   // setSprite 188
        step(&state)                                                    // playVoice (seam)
        step(&state)                                                    // setTimeout 7
        step(&state); #expect(state.explosions[slot].spriteID == 189)   // setSprite 189
        step(&state)                                                    // bloom (seam)
        step(&state)                                                    // screenShake (seam)
        step(&state)                                                    // setTimeout 3
        step(&state); #expect(state.explosions[slot].spriteID == 190)
        step(&state)                                                    // setTimeout 3
        step(&state); #expect(state.explosions[slot].spriteID == 191)
        step(&state)                                                    // setTimeout 3
        step(&state); #expect(state.explosions[slot].spriteID == 192)
        step(&state)                                                    // setTimeout 3
        step(&state)                                                    // stop
        #expect(!state.explosions[slot].active)
    }

    @Test("a second explosion on the same tile stops the first")
    func stopAtPosition() {
        var state = GameState()
        let pos = Tile32.unpack(Tile32.packXY(x: 3, y: 3))
        state.explosionStart(type: ExplosionType.impactSmall.rawValue, position: pos)
        let first = try! #require(state.explosions.firstIndex { $0.active })

        state.explosionStart(type: ExplosionType.tankExplode.rawValue, position: pos)
        // The first slot was freed and reused (only one active explosion remains on the tile).
        let active = state.explosions.indices.filter { state.explosions[$0].active }
        #expect(active.count == 1)
        #expect(state.explosions[active[0]].tableIndex == ExplosionType.tankExplode.rawValue)
        #expect(first == active[0])   // reused the freed slot
        #expect(state.map[Int(pos.packed)].hasExplosion)
    }

    @Test("all 20 command tables are present and STOP-terminated")
    func tablesWellFormed() {
        #expect(ExplosionTables.commands.count == ExplosionType.max)
        for table in ExplosionTables.commands {
            #expect(table.last?.command == .stop)
        }
    }
}
