import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// The area-effect combat seams wired into `Unit_Move` / `Unit_Damage`: sonic-blast area damage, the
/// death-hand 17-point blast, saboteur arrival detonation, the `range != 0` impact crater, and the
/// sand-burst on empty sand. Decision-trace style — each drives the real `move()` / `damage()`.
@Suite("Area-effect combat seams")
struct AreaEffectCombatTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> (GameState, UnitMovement) {
        var s = GameState()
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        return (s, UnitMovement(scriptInfo: info))
    }

    /// Place a unit and register it on its map tile so `Unit_Get_ByPackedTile` resolves it.
    private func addOnMap(_ s: inout GameState, _ type: UnitType, at packed: UInt16, hp: UInt16, index: UInt16) -> Int {
        let slot = s.unitAllocate(index: index, type: UInt8(type.rawValue), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(packed)
        s.units[slot].o.hitpoints = hp
        s.unitUpdateMap(1, slot)
        return slot
    }

    private var activeExplosions: (GameState) -> Int { { s in s.explosions.filter(\.active).count } }

    // MARK: - Sonic blast

    @Test("a sonic blast damages a vulnerable unit on its tile and drains its own HP")
    func sonicBlastDamages() {
        var (s, move) = base()
        let sonic = s.unitAllocate(index: 0, type: UInt8(UnitType.sonicBlast.rawValue), houseID: 0)!
        s.units[sonic].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.units[sonic].o.hitpoints = 100
        s.units[sonic].fireDelay = 10     // survives the step (not 0)
        move.unit.setOrientation(&s.units[sonic], orientation: 64, rotateInstantly: true, level: 0)  // east

        let victim = addOnMap(&s, .trike, at: Tile32.packXY(x: 11, y: 10), hp: 100, index: 1)
        #expect(s.unitGetByPackedTile(Tile32.packXY(x: 11, y: 10)) == victim)

        move.move(slot: sonic, distance: 255, in: &s)

        #expect(s.units[victim].o.hitpoints == 100 - (100 / 4 + 1))   // hp/4 + 1 = 26
        #expect(s.units[sonic].o.hitpoints == 99)                     // self-drains 1 per step
    }

    @Test("a sonic blast spares a sonic-protected unit (Sonic Tank)")
    func sonicBlastSparesProtected() {
        var (s, move) = base()
        let sonic = s.unitAllocate(index: 0, type: UInt8(UnitType.sonicBlast.rawValue), houseID: 0)!
        s.units[sonic].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.units[sonic].o.hitpoints = 100
        s.units[sonic].fireDelay = 10
        move.unit.setOrientation(&s.units[sonic], orientation: 64, rotateInstantly: true, level: 0)

        let tank = addOnMap(&s, .sonicTank, at: Tile32.packXY(x: 11, y: 10), hp: 110, index: 1)
        #expect(UnitInfo[.sonicTank].flags.contains(.sonicProtection))

        move.move(slot: sonic, distance: 255, in: &s)
        #expect(s.units[tank].o.hitpoints == 110)   // immune
    }

    // MARK: - Saboteur detonation

    @Test("a saboteur detonates on reaching its move target and is removed")
    func saboteurDetonates() {
        var (s, move) = base()
        let sab = s.unitAllocate(index: 0, type: UInt8(UnitType.saboteur.rawValue), houseID: 0)!
        s.units[sab].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.units[sab].o.hitpoints = 40
        s.units[sab].currentDestination = Tile32.unpack(Tile32.packXY(x: 11, y: 10))   // arrives this step
        s.units[sab].targetMove = s.indexEncode(Tile32.packXY(x: 10, y: 10), type: .tile)  // within 32 → detonate
        move.unit.setOrientation(&s.units[sab], orientation: 64, rotateInstantly: true, level: 0)

        let ret = move.move(slot: sab, distance: 255, in: &s)
        #expect(ret)                                          // waypoint completed (removed)
        #expect(!s.units[sab].o.flags.contains(.used))        // Unit_Remove fired
        #expect(activeExplosions(s) >= 1)                     // EXPLOSION_SABOTEUR_DEATH started
    }

    // MARK: - range != 0 impact crater

    @Test("a ranged hit on a survivor leaves a visual impact crater (no further damage)")
    func rangedHitMakesCrater() {
        var (s, move) = base()
        let u = addOnMap(&s, .trike, at: Tile32.packXY(x: 20, y: 20), hp: 100, index: 0)
        let died = move.damage(slot: u, damage: 10, range: 1, in: &s)   // 10 < 25 → IMPACT_SMALL
        #expect(!died)
        #expect(s.units[u].o.hitpoints == 90)
        #expect(activeExplosions(s) == 1)
    }

    @Test("a range-0 hit (the common case) makes no crater")
    func zeroRangeNoCrater() {
        var (s, move) = base()
        let u = addOnMap(&s, .trike, at: Tile32.packXY(x: 20, y: 20), hp: 100, index: 0)
        _ = move.damage(slot: u, damage: 10, range: 0, in: &s)
        #expect(activeExplosions(s) == 0)
    }

    // MARK: - Death-hand 17-point blast

    @Test("a house missile's death-hand blast damages units near the impact and is removed")
    func deathHandBlast() {
        var (s, move) = base()
        let missile = s.unitAllocate(index: 0, type: UInt8(UnitType.missileHouse.rawValue), houseID: 0)!
        s.units[missile].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.units[missile].o.hitpoints = 200
        s.units[missile].fireDelay = 0   // armed → detonates on arrival
        s.units[missile].currentDestination = Tile32.unpack(Tile32.packXY(x: 11, y: 10))
        move.unit.setOrientation(&s.units[missile], orientation: 64, rotateInstantly: true, level: 0)

        let victim = addOnMap(&s, .trike, at: Tile32.packXY(x: 11, y: 10), hp: 100, index: 1)

        let ret = move.move(slot: missile, distance: 255, in: &s)
        #expect(ret)
        #expect(!s.units[missile].o.flags.contains(.used))   // missile removed
        #expect(s.units[victim].o.hitpoints < 100)           // caught in the blast
        #expect(activeExplosions(s) >= 1)
    }
}
