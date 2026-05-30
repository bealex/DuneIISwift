import Testing
import DuneIIContracts
@testable import DuneIIWorld

/// Fog-of-war primitives (`Map_UnveilTile` / `Tile_RemoveFogInRadius` / `Unit_RemoveFog`): the player's
/// tile visibility + the `seenByHouses` reveal it drives. (Wiring into the unit scripts lands with the
/// combat slice; these pin the primitives directly.)
@Suite("Fog of war")
struct FogTests {
    private func world() -> GameState {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        return s
    }

    @Test("Map_UnveilTile lifts the player's fog only, and reveals an enemy standing there")
    func unveil() {
        var s = world()
        // An enemy unit on tile 1040, registered on the map so Unit_Get_ByPackedTile finds it.
        let enemy = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 2)!
        s.units[enemy].o.flags.insert([.used, .allocated])
        s.units[enemy].o.position = Tile32.unpack(1040)
        s.map[1040].hasUnit = true
        s.map[1040].index = UInt8(enemy + 1)

        #expect(!s.map[1040].isUnveiled)
        #expect(s.mapUnveilTile(1040, houseID: 1) == false)   // non-player ⇒ no-op
        #expect(!s.map[1040].isUnveiled)

        #expect(s.mapUnveilTile(1040, houseID: 0) == true)    // player ⇒ unveils
        #expect(s.map[1040].isUnveiled)
        #expect(s.units[enemy].o.seenByHouses & (1 << 0) != 0) // enemy now seen by the player
        #expect(s.mapUnveilTile(1040, houseID: 0) == false)   // already clear ⇒ no-op
    }

    @Test("Tile_RemoveFogInRadius unveils the disc within the radius")
    func radius() {
        var s = world()
        let centre = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.tileRemoveFogInRadius(centre, radius: 1)

        // Centre + its 4 orthogonal neighbours are within rounded distance 1; diagonals are distance 2.
        #expect(s.map[Int(Tile32.packXY(x: 10, y: 10))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 11, y: 10))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 9, y: 10))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 10, y: 11))].isUnveiled)
        #expect(s.map[Int(Tile32.packXY(x: 10, y: 9))].isUnveiled)
        #expect(!s.map[Int(Tile32.packXY(x: 11, y: 11))].isUnveiled)   // diagonal ⇒ out of radius 1
        #expect(!s.map[Int(Tile32.packXY(x: 12, y: 10))].isUnveiled)   // 2 away
    }

    @Test("Unit_RemoveFog reveals around a placed unit, but an unplaced unit reveals nothing")
    func unitFog() {
        var s = world()
        let u = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        s.units[u].o.flags.insert([.used, .allocated])

        // Position 0:0 ⇒ treated as unplaced ⇒ no reveal.
        s.units[u].o.position = Tile32(x: 0, y: 0)
        s.unitRemoveFog(u)
        #expect(!s.map[0].isUnveiled)

        // Placed ⇒ reveals at least its own tile (tank fogUncoverRadius > 0).
        s.units[u].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        s.unitRemoveFog(u)
        #expect(s.map[Int(Tile32.packXY(x: 20, y: 20))].isUnveiled)
    }
}
