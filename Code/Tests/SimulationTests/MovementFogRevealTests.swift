import DuneIIContracts
import DuneIIWorld
import Testing

@testable import DuneIISimulation

/// `fullSightMovementReveal` — the client toggle that makes a moving player unit lift the player's fog
/// over its **full `fogUncoverRadius`** every tile (the original game's look) instead of OpenDUNE's
/// radius-1 trail. Exercises the gate in `unitUpdateMap(1)`. Off by default ⇒ byte-identical to the
/// faithful path (the scenario goldens are the neutrality bar; see `ScenarioGoldenTests`).
@Suite("Movement fog reveal (full-sight toggle)")
struct MovementFogRevealTests {
    private func state(with flag: Bool) -> (GameState, Int) {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        s.fullSightMovementReveal = flag
        for i in 0 ..< 64 * 64 { s.map[i].isUnveiled = false }

        let slot = s.unitAllocate(index: 0, type: UInt8(UnitType.trike.rawValue), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        return (s, slot)
    }

    private func unveiled(_ s: GameState, x: UInt16, y: UInt16) -> Bool {
        s.map[Int(Tile32.packXY(x: x, y: y))].isUnveiled
    }

    @Test("trike fogUncoverRadius is 2 (the radius the disc should reach)")
    func radiusIsTwo() {
        #expect(UnitInfo[.trike].o.fogUncoverRadius == 2)
    }

    @Test("flag OFF: a moving unit lifts only the radius-1 trail (faithful)")
    func offRevealsRadiusOne() {
        var (s, slot) = state(with: false)
        s.unitUpdateMap(1, slot)
        #expect(unveiled(s, x: 20, y: 20))  // current tile
        #expect(unveiled(s, x: 21, y: 20))  // 1 east — within radius 1
        #expect(!unveiled(s, x: 22, y: 20))  // 2 east — outside radius 1, still fogged
    }

    @Test("flag ON: a moving unit lifts the full fogUncoverRadius disc")
    func onRevealsFullDisc() {
        var (s, slot) = state(with: true)
        s.unitUpdateMap(1, slot)
        #expect(unveiled(s, x: 20, y: 20))  // current tile
        #expect(unveiled(s, x: 22, y: 20))  // 2 east — now within the full radius-2 disc
        #expect(unveiled(s, x: 20, y: 22))  // 2 south
        #expect(unveiled(s, x: 18, y: 20))  // 2 west
        #expect(!unveiled(s, x: 23, y: 20))  // 3 east — beyond radius 2, still fogged
    }

    @Test("flag ON: re-stamps the disc even when the current tile is already unveiled")
    func onReStampsOverExploredGround() {
        // Pre-unveil only the current tile (as if the unit drove onto already-explored ground). The
        // faithful path would skip the reveal entirely (guarded on `!isUnveiled`); the toggle must still
        // re-stamp the full disc so the sight circle tracks the unit across explored terrain.
        var (s, slot) = state(with: true)
        s.map[Int(Tile32.packXY(x: 20, y: 20))].isUnveiled = true
        s.unitUpdateMap(1, slot)
        #expect(unveiled(s, x: 22, y: 20))
    }

    @Test("flag ON: an enemy unit still reveals nothing (player-allied only)")
    func onEnemyRevealsNothing() {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[2].unitCountMax = 100
        s.fullSightMovementReveal = true
        for i in 0 ..< 64 * 64 { s.map[i].isUnveiled = false }
        let enemy = s.unitAllocate(index: 0, type: UInt8(UnitType.trike.rawValue), houseID: 2)!
        s.units[enemy].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        s.unitUpdateMap(1, enemy)
        #expect(!unveiled(s, x: 20, y: 20))
        #expect(!unveiled(s, x: 22, y: 20))
    }
}
