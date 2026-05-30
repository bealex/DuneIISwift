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
}
