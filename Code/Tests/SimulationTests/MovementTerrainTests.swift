import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Verifies `Unit_StartMovement` (`unit.c:1059`) sets the per-step speed from the **terrain of the tile
/// being entered** — i.e. terrain is accounted for *at the start* of each move, not only mid-traversal.
/// (The whole-trajectory `moving`/`move-trike`/`trooper` goldens already confirm this end-to-end over real
/// `Map_CreateLandscape` terrain; this pins the mechanism directly.)
@Suite("Movement start speed ← entered-tile terrain")
struct MovementTerrainTests {
    /// Distinct tile-id anchors so a small `groundTileID` resolves purely by `landscapeSpriteMap`:
    /// landscape base 0 (offset == groundTileID), the others parked far away so tile 0/1 aren't mistaken
    /// for slab/bloom/wall.
    private func tileIDs() -> TileIDs {
        var t = TileIDs(); t.landscape = 0; t.builtSlab = 1000; t.bloom = 2000; t.wall = 3000; t.veiled = 4000
        return t
    }

    /// groundTileID whose `landscapeSpriteMap[offset]` is the wanted type: 0 → normalSand, 1 → partialRock.
    private let sandTile: UInt16 = 0   // landscapeSpriteMap[0] = 0 (normalSand)  → wheeled speed 160
    private let rockTile: UInt16 = 1   // landscapeSpriteMap[1] = 1 (partialRock) → wheeled speed 64

    /// Place a full-HP trike (wheeled) facing north at tile (20,20), set the current tile and the
    /// tile-being-entered (one row north, packed−64) to the given terrain, run `Unit_StartMovement`,
    /// and return whether it started + the resulting `speedPerTick`.
    private func startSpeed(currentTile: UInt16, enteredTile: UInt16) -> (started: Bool, speedPerTick: UInt8) {
        var s = GameState()
        s.tileIDs = tileIDs()
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: UInt8(UnitType.trike.rawValue), houseID: 0)!
        let packed = Tile32.packXY(x: 20, y: 20)
        s.units[slot].o.position = Tile32.unpack(packed)
        s.units[slot].o.hitpoints = UnitInfo[.trike].o.hitpoints   // full HP → no half-HP penalty
        s.units[slot].orientation[0].current = 0                   // faces north ⇒ entered tile = packed − 64
        s.map[Int(packed)].groundTileID = currentTile
        s.map[Int(packed) - 64].groundTileID = enteredTile
        let movement = UnitMovement(scriptInfo: ScriptInfo(program: [0], offsets: [UInt16](repeating: 0, count: 64)))
        var engine = s.units[slot].o.script
        let started = movement.startMovement(slot: slot, engine: &engine, in: &s)
        return (started, s.units[slot].speedPerTick)
    }

    @Test("the start speed comes from the entered tile's terrain, not the tile the unit sits on")
    func enteredTileDrivesStartSpeed() {
        // Current = rock (slow), entering = sand (fast) ⇒ should be fast (uses the entered tile).
        let fast = startSpeed(currentTile: rockTile, enteredTile: sandTile)
        // Current = sand (fast), entering = rock (slow) ⇒ should be slow (uses the entered tile).
        let slow = startSpeed(currentTile: sandTile, enteredTile: rockTile)

        #expect(fast.started && slow.started)
        // If the *current* tile were used, these would be swapped. Entering sand is faster than rock.
        #expect(fast.speedPerTick > slow.speedPerTick)
    }

    @Test("entering different terrain yields the terrain's movementSpeed (sand 160 > rock 64 for wheeled)")
    func speedTracksTerrain() {
        #expect(LandscapeInfo[.normalSand].speed(.wheeled) == 160)
        #expect(LandscapeInfo[.partialRock].speed(.wheeled) == 64)
        let onSand = startSpeed(currentTile: sandTile, enteredTile: sandTile)
        let onRock = startSpeed(currentTile: rockTile, enteredTile: rockTile)
        #expect(onSand.speedPerTick > onRock.speedPerTick)
    }
}
