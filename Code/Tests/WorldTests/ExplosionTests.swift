import Testing
import DuneIIContracts
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
        state.soundEvents.removeAll()
        step(&state)                                                    // playVoice 51 → emits a sound
        #expect(state.soundEvents.contains { $0.sound == SoundID(51) && $0.positionX == Int(pos.x) })
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

    @Test("emitSound queues an in-range voice and ignores the out-of-range / 0xFFFF sentinel")
    func emitSoundBounds() {
        var state = GameState()
        let pos = Tile32.unpack(Tile32.packXY(x: 3, y: 7))
        state.emitSound(57, at: pos)        // valid
        state.emitSound(0xFFFF, at: pos)    // no-sound sentinel
        state.emitSound(-1, at: pos)        // below range
        state.emitSound(120, at: pos)       // above range
        #expect(state.soundEvents.count == 1)
        #expect(state.soundEvents[0].sound == SoundID(57))
        #expect(state.soundEvents[0].positionX == Int(pos.x))
        #expect(state.soundEvents[0].positionY == Int(pos.y))
    }

    @Test("TILE_DAMAGE blasts a built concrete slab back to the base landscape tile (slabs are destructible)")
    func slabDestruction() {
        var state = GameState()
        state.tileIDs.builtSlab = 100; state.tileIDs.wall = 50; state.tileIDs.veiled = 200
        let p = Int(Tile32.packXY(x: 9, y: 9))
        func makeSlab() {
            state.map[p].groundTileID = 100       // a built concrete slab
            state.map[p].isUnveiled = true
            state.map[p].overlayTileID = 0        // revealed (0 < veiled − 15)
            state.map[p].hasStructure = false
            state.mapBaseTileID[p] = 30           // the seed base landscape tile under it
        }
        // The slab is blasted back to the base tile (Explosion_Func_TileDamage's LST_CONCRETE_SLAB branch).
        makeSlab(); state.explosionTileDamage(UInt16(p))
        #expect(state.map[p].groundTileID == 30)
        // A veiled tile is untouched (Map_IsPositionUnveiled false).
        makeSlab(); state.map[p].isUnveiled = false; state.explosionTileDamage(UInt16(p))
        #expect(state.map[p].groundTileID == 100)
        // A structure tile (LST_STRUCTURE) is skipped.
        makeSlab(); state.map[p].hasStructure = true; state.explosionTileDamage(UInt16(p))
        #expect(state.map[p].groundTileID == 100)
        // An already-destroyed wall (overlay == wall id, LST_DESTROYED_WALL) is skipped.
        makeSlab(); state.map[p].overlayTileID = 50; state.explosionTileDamage(UInt16(p))
        #expect(state.map[p].groundTileID == 100)
        // A non-slab tile (sand) gets no slab revert here; the crater overlay is stamped by `drainCraters`.
        makeSlab(); state.map[p].groundTileID = 77; state.explosionTileDamage(UInt16(p))
        #expect(state.map[p].groundTileID == 77)
    }

    @Test("TILE_DAMAGE records an open unveiled tile for the crater drain, but skips structure/wall/fogged")
    func craterRecording() {
        var state = GameState()
        state.tileIDs.builtSlab = 100; state.tileIDs.wall = 50; state.tileIDs.veiled = 200
        let p = Int(Tile32.packXY(x: 9, y: 9))
        func openTile() {
            state.pendingCraters = []
            state.map[p] = MapTile()
            state.map[p].groundTileID = 77; state.map[p].isUnveiled = true; state.map[p].overlayTileID = 0
        }
        openTile(); state.explosionTileDamage(UInt16(p))
        #expect(state.pendingCraters == [UInt16(p)])          // recorded for drainCraters
        openTile(); state.map[p].hasStructure = true; state.explosionTileDamage(UInt16(p))
        #expect(state.pendingCraters.isEmpty)                 // a structure tile records nothing
        openTile(); state.map[p].isUnveiled = false; state.explosionTileDamage(UInt16(p))
        #expect(state.pendingCraters.isEmpty)                 // a fogged tile records nothing
    }

    @Test("the IMPACT_EXPLODE sequence reaches TILE_DAMAGE and destroys the slab in the VM")
    func slabDestructionViaVM() {
        var state = GameState()
        state.tileIDs.builtSlab = 100; state.tileIDs.wall = 50; state.tileIDs.veiled = 200
        let pos = Tile32.unpack(Tile32.packXY(x: 7, y: 7))
        let p = Int(pos.packed)
        state.map[p].groundTileID = 100; state.map[p].isUnveiled = true; state.map[p].overlayTileID = 0
        state.mapBaseTileID[p] = 30
        // A Launcher rocket impact is EXPLOSION_IMPACT_EXPLODE; its TILE_DAMAGE command reverts the slab.
        state.explosionStart(type: ExplosionType.impactExplode.rawValue, position: pos)
        for _ in 0 ..< 8 where state.map[p].groundTileID != 30 { step(&state) }
        #expect(state.map[p].groundTileID == 30)
    }

    @Test("an explosion sitting on a spice bloom queues it for detonation at the BLOOM command")
    func bloomExplosionQueuesDetonation() {
        var state = GameState()
        state.tileIDs.bloom = 200
        let pos = Tile32.unpack(Tile32.packXY(x: 6, y: 6))
        let p = Int(pos.packed)
        state.map[p].groundTileID = 200                 // the bloom under the blast
        state.explosionStart(type: ExplosionType.impactSmall.rawValue, position: pos)
        // [setSprite 153, setTimeout 3, BLOOM, …] — step to the BLOOM command.
        step(&state)                                    // setSprite
        step(&state)                                    // setTimeout
        #expect(state.pendingBloomDetonations.isEmpty)
        step(&state)                                    // BLOOM → queues the tile
        #expect(state.pendingBloomDetonations == [UInt16(p)])
    }

    @Test("an explosion on a non-bloom tile queues nothing at the BLOOM command")
    func bloomExplosionSkipsNonBloom() {
        var state = GameState()
        state.tileIDs.bloom = 200
        let pos = Tile32.unpack(Tile32.packXY(x: 6, y: 6))
        state.map[Int(pos.packed)].groundTileID = 50    // not a bloom
        state.explosionStart(type: ExplosionType.impactSmall.rawValue, position: pos)
        step(&state); step(&state); step(&state)        // through the BLOOM command
        #expect(state.pendingBloomDetonations.isEmpty)
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
