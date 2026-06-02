import DuneIIContracts
import Foundation
import Testing
@testable import DuneIIWorld

/// The "squish" sound when infantry is crushed under a tracked/heavy unit. Driving over a foot unit sets its
/// `script.variables[1] = 1` (`Unit_Move`, `unit.c:1337`); `Script_Unit_StartAnimation` (`script/unit.c:1475`)
/// then adds 2 to the death-animation row, selecting `g_table_animation_unitScript1/2` rows 2 & 3 — the only
/// ones carrying `ANIMATION_PLAY_VOICE 35` (= `g_table_voiceMapping[35]` → `+SQUISH2.VOC`). The normal-death
/// rows 0 & 1 are silent. This locks that the squished-death animation actually emits the squish voice.
@Suite("Unit death animation — squish voice")
struct UnitDeathAnimationTests {
    /// Run a unit-death corpse animation (row of `kind`) past its opening commands and report whether it
    /// emitted the squish voice (`SoundID(35)`, the `Animation_Func_PlayVoice` cue).
    private func emitsSquish(kind: AnimationKind, row: Int) -> Bool {
        var state = GameState()
        state.animationStart(tableIndex: row, tile: Tile32(x: 2560, y: 2560), tileLayout: 0, houseID: 0,
                             iconGroup: 4, kind: kind)
        for _ in 0 ..< 6 { state.animationTick() }   // step through SET_OVERLAY_TILE → PLAY_VOICE → PAUSE
        return state.soundEvents.contains { $0.sound == SoundID(35) }
    }

    @Test("squished rows (2,3) play voice 35; normal rows (0,1) are silent — both infantry display modes")
    func squishVoiceRows() {
        for kind in [AnimationKind.unitScript1, .unitScript2] {
            #expect(emitsSquish(kind: kind, row: 2), "\(kind) row 2 (squished) should play the squish voice")
            #expect(emitsSquish(kind: kind, row: 3), "\(kind) row 3 (squished) should play the squish voice")
            #expect(!emitsSquish(kind: kind, row: 0), "\(kind) row 0 (normal death) must be silent")
            #expect(!emitsSquish(kind: kind, row: 1), "\(kind) row 1 (normal death) must be silent")
        }
    }
}
