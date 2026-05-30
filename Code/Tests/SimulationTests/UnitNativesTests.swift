import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Common unit-script natives ported this slice: `SetSprite` (0x13), `Blink` (0x0B),
/// `SetActionDefault` (0x0A), and `MoveToTarget` (0x16, the fine-approach homing).
@Suite("Unit natives (set-sprite / blink / default-action / move-to-target)")
struct UnitNativesTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func setup(_ type: UnitType = .carryall) -> (GameState, Int, UnitMovement, UnitScriptFunctions) {
        var s = GameState()
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))
        return (s, slot, UnitMovement(scriptInfo: info), UnitScriptFunctions(unitPrimitives: DefaultUnitPrimitives()))
    }

    @Test("SetSprite stores a negative spriteOffset (the death-frame index)")
    func setSprite() {
        var (s, slot, _, f) = setup()
        _ = f.setSprite(slot: slot, value: 1, in: &s)
        #expect(s.units[slot].spriteOffset == -1)
        _ = f.setSprite(slot: slot, value: 5, in: &s)
        #expect(s.units[slot].spriteOffset == -5)
    }

    @Test("Blink sets the 32-tick blink counter")
    func blink() {
        var (s, slot, _, f) = setup()
        _ = f.blink(slot: slot, in: &s)
        #expect(s.units[slot].blinkCounter == 32)
    }

    @Test("SetActionDefault switches the unit to its type's default player action")
    func setActionDefault() {
        var (s, slot, _, f) = setup(.tank)   // tank actionsPlayer[3] = Guard
        var engine = s.units[slot].o.script
        _ = f.setActionDefault(slot: slot, scriptInfo: info, actions: UnitActions(), engine: &engine, in: &s)
        #expect(s.units[slot].actionID == UInt8(ActionType.guard_.rawValue))
    }

    @Test("MoveToTarget with no destination is a no-op")
    func moveNoTarget() {
        var (s, slot, m, _) = setup()
        var engine = s.units[slot].o.script
        #expect(m.moveToTarget(slot: slot, engine: &engine, in: &s) == 0)
    }

    @Test("MoveToTarget arrives (distance < 32) → returns 1")
    func moveArrives() {
        var (s, slot, m, _) = setup()
        let target = Tile32.packXY(x: 20, y: 20)             // the unit's own (centred) tile
        s.units[slot].targetMove = s.indexEncode(target, type: .tile)
        var engine = s.units[slot].o.script
        #expect(m.moveToTarget(slot: slot, engine: &engine, in: &s) == 1)
    }

    @Test("MoveToTarget close-but-not-arrived steps toward the target and re-runs (PC rewind + delay)")
    func moveCloseReRuns() {
        var (s, slot, m, _) = setup()
        let target = Tile32.packXY(x: 20, y: 20)
        s.units[slot].o.position = Tile32(x: Tile32.unpack(target).x &- 100, y: Tile32.unpack(target).y)  // ~100 away (32…128)
        s.units[slot].targetMove = s.indexEncode(target, type: .tile)
        let startX = s.units[slot].o.position.x
        var engine = s.units[slot].o.script
        engine.scriptPC = 5
        let r = m.moveToTarget(slot: slot, engine: &engine, in: &s)
        #expect(r == 0)
        #expect(engine.scriptPC == 4)                        // rewound one word to re-run the opcode
        #expect(engine.delay == 2)
        #expect(s.units[slot].o.position.x == startX &+ 16)  // stepped +16 toward the target
    }

    @Test("MoveToTarget far (distance ≥ 128) aims + sets a speed and re-runs")
    func moveFar() {
        var (s, slot, m, _) = setup()
        let target = Tile32.packXY(x: 24, y: 20)             // 4 tiles east → distance ≥ 128
        s.units[slot].targetMove = s.indexEncode(target, type: .tile)
        var engine = s.units[slot].o.script
        engine.scriptPC = 5
        let r = m.moveToTarget(slot: slot, engine: &engine, in: &s)
        #expect(r == 0)
        #expect(engine.scriptPC == 4)
        #expect(s.units[slot].speedPerTick > 0 || s.units[slot].speed > 0)   // a move speed was set
    }

    @Test("ExplosionMultiple starts the death-hand blast at the unit")
    func explosionMultiple() {
        var (s, slot, m, _) = setup()
        let pos = s.units[slot].o.position
        _ = m.explosionMultiple(slot: slot, radius: 256, in: &s)
        #expect(s.map[Int(pos.packed)].hasExplosion)             // the central blast
        #expect(s.explosions.contains { $0.active })
    }

    @Test("findIdle returns an idle structure of the type/house, 0 when it's busy")
    func findIdle() {
        var (s, slot, _, f) = setup()                            // carryall, house 0
        let r = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[r].o.houseID = 0
        s.structures[r].state = .idle
        #expect(f.findIdle(slot: slot, index: UInt16(StructureType.refinery.rawValue), in: s) != 0)
        s.structures[r].state = .busy
        #expect(f.findIdle(slot: slot, index: UInt16(StructureType.refinery.rawValue), in: s) == 0)
    }

    @Test("targetPriority scores a seen enemy and returns 0 for an unresolvable target")
    func targetPriority() {
        var (s, slot, _, _) = setup(.tank)                       // house 0
        _ = s.houseAllocate(index: 2); s.houses[2].unitCountMax = 100
        let enemy = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 2)!
        s.units[enemy].o.position = Tile32.unpack(Tile32.packXY(x: 22, y: 20))
        s.units[enemy].o.seenByHouses |= UInt8(1 << 0)
        let targets = TargetFinder()
        let encoded = s.indexEncode(s.units[enemy].o.index, type: .unit)
        #expect(targets.targetPriority(unitSlot: slot, encoded: encoded, in: s) > 0)
        #expect(targets.targetPriority(unitSlot: slot, encoded: 0, in: s) == 0)
    }

    @Test("isValidDestination: own-house structure → 0; a tile with no passenger → 1")
    func isValidDestination() {
        var (s, slot, m, _) = setup(.carryall)                   // house 0, no passenger (linkedID 0xFF)
        let combat = UnitCombat(movement: m)
        let r = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[r].o.houseID = 0
        let structEnc = s.indexEncode(s.structures[r].o.index, type: .structure)
        #expect(combat.isValidDestination(slot: slot, encoded: structEnc, in: &s) == 0)   // own house
        let tileEnc = s.indexEncode(Tile32.packXY(x: 22, y: 20), type: .tile)
        #expect(combat.isValidDestination(slot: slot, encoded: tileEnc, in: &s) == 1)     // no passenger
    }
}
