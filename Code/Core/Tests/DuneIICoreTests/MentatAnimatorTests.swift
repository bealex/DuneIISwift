import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

/// Slice 2 of the Mentat briefing port (2026-04-23). Pins the pure
/// `MentatAnimator` state machine — the scene drives it every frame
/// and re-reads `mouthFrame` / `eyesFrame` / `otherFrame` to pick
/// sprite textures. Rendering is manual-verification only (see
/// `Documentation/Algorithms/MentatBriefing.md`); this file covers
/// every timer / frame transition the animator can make.
///
/// All tests use a deterministic RNG — either a fixed-sequence mock
/// or a `BorlandLCG` with a pinned seed — so the cadence is
/// reproducible run-over-run.
@MainActor
@Suite("MentatAnimator — mouth / eye / other cadence (slice 2)")
struct MentatAnimatorTests {

    /// Emit a sequence of canned values clamped to each call's
    /// `[lo, hi]` range — mirrors `Tools_RandomLCG_Range`'s invariant.
    /// Loops if exhausted so a test doesn't accidentally fall off the
    /// end.
    private final class SequenceRNG {
        var values: [UInt16]
        var cursor: Int = 0
        init(_ vs: [UInt16]) { self.values = vs }
        func range(_ lo: UInt16, _ hi: UInt16) -> UInt16 {
            defer { cursor = (cursor + 1) % values.count }
            let v = values[cursor]
            if v < lo { return lo }
            if v > hi { return hi }
            return v
        }
    }

    /// Builds an animator with the "other" branch effectively muted
    /// so `advanceOther` doesn't consume RNG values meant for the
    /// mouth / eye assertions. Tests that DO care about "other" set
    /// the timer back to 0 explicitly.
    private func animatorWithMutedOther(_ otherFrameCount: Int = 0) -> MentatAnimator {
        var a = MentatAnimator(otherFrameCount: otherFrameCount)
        a.otherTimer = UInt32.max    // never fires
        return a
    }

    // MARK: - Mouth

    @Test("Speaking mode: mouth picks a random frame and schedules next tick")
    func speakingMouthPicksFrame() {
        var a = animatorWithMutedOther()
        let rng = SequenceRNG([4, 5])  // frame=4 → rng(5,6)=5
        a.tick(now: 1, speakingMode: .speaking,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.mouthFrame == 4)
        #expect(a.mouthTimer == 6, "frame 4 dwells for rng(5,6) ticks ahead of now")
    }

    @Test("Speaking mode: mouth frame 0 dwells 7..30 ticks")
    func speakingMouthFrame0Dwell() {
        var a = animatorWithMutedOther()
        let rng = SequenceRNG([0, 7])  // frame=0 → rng(7,30)=7
        a.tick(now: 10, speakingMode: .speaking,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.mouthFrame == 0)
        #expect(a.mouthTimer == 17)
    }

    @Test("Idle mode closes the mouth and clears the timer")
    func idleClosesMouth() {
        var a = animatorWithMutedOther()
        a.mouthFrame = 4
        a.mouthTimer = 99
        a.tick(now: 10, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: { _, _ in 0 })
        #expect(a.mouthFrame == 0)
        #expect(a.mouthTimer == 0)
    }

    @Test("Speaking mouth doesn't re-pick before its timer expires")
    func mouthWaitsForTimer() {
        var a = animatorWithMutedOther()
        a.mouthFrame = 2
        a.mouthTimer = 100    // future
        let rng = SequenceRNG([3])
        a.tick(now: 50, speakingMode: .speaking,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.mouthFrame == 2, "mouth locked until mouthTimer < now")
    }

    // MARK: - Eyes

    @Test("Idle eyes: rng=0 picks frame 0 with a 15..180-tick dwell")
    func idleEyesPickFrame0() {
        var a = animatorWithMutedOther()
        let rng = SequenceRNG([0, 20])  // eyesFrame=0 → rng(15,180)=20
        a.tick(now: 10, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.eyesFrame == 0)
        #expect(a.eyesTimer == 30)
    }

    @Test("Idle eyes: rng=5 picks blink frame 4; 6..60-tick dwell")
    func idleEyesPickBlink() {
        var a = animatorWithMutedOther()
        let rng = SequenceRNG([5, 15])  // r=5 → i=4; rng(6,60)=15
        a.tick(now: 100, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        // Entering frame 4 always dwells on frame 3 first; queued next
        // is 4.
        #expect(a.eyesFrame == 3)
        #expect(a.eyesNextFrame == 4)
    }

    @Test("Idle eyes: deferred frame lands after the dwell")
    func idleEyesDeferredLand() {
        var a = animatorWithMutedOther()
        a.eyesFrame = 3
        a.eyesNextFrame = 4
        a.eyesTimer = 0    // already elapsed
        let rng = SequenceRNG([20])   // frame=4 → rng(12,30)=20
        a.tick(now: 100, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.eyesFrame == 4)
        #expect(a.eyesNextFrame == 0)
        #expect(a.eyesTimer == 120)
    }

    @Test("Eyes 1→2 flip bounces through frame 0 for 1..5 ticks")
    func eyesFlipBouncesThroughZero() {
        var a = animatorWithMutedOther()
        a.eyesFrame = 1
        let rng = SequenceRNG([2, 3])    // r=2 → i=2; bounce dwell rng(1,5)=3
        a.tick(now: 10, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.eyesFrame == 0)
        #expect(a.eyesNextFrame == 2)
        #expect(a.eyesTimer == 13)
    }

    @Test("Eyes respect timer — no transition before expiry")
    func eyesWaitForTimer() {
        var a = animatorWithMutedOther()
        a.eyesFrame = 2
        a.eyesTimer = 100
        a.tick(now: 50, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: { _, _ in 0 })
        #expect(a.eyesFrame == 2)
    }

    @Test("Speaking + eyes not at 0 → forced back to 0 on next tick")
    func speakingEyesSnapToZero() {
        var a = animatorWithMutedOther()
        a.eyesFrame = 2
        a.eyesTimer = 0
        let rng = SequenceRNG([50])   // non-zero frame → rng(15,180)=50
        a.tick(now: 10, speakingMode: .speaking,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.eyesFrame == 0,
                "speaking mode pulls eyes back to centre when they strayed")
    }

    // MARK: - Other (book / ring)

    @Test("Atreides other: timer reschedules at 60 * rng(1..3)")
    func otherAtreidesReschedule() {
        var a = MentatAnimator(otherFrameCount: 2)
        let rng = SequenceRNG([2])    // rng(1,3)=2 → 60 * 2 = 120
        a.tick(now: 10, speakingMode: .idle,
               playerHouseID: Simulation.House.atreides,
               rng: rng.range)
        #expect(a.otherTimer == 130, "10 + 60*2 = 130")
        #expect(a.otherFrame == 1)
    }

    @Test("Ordos other: quick flip after a held frame")
    func otherOrdosFastAfterHold() {
        var a = MentatAnimator(otherFrameCount: 2)
        a.otherFrame = 0    // held
        let rng = SequenceRNG([10])   // would be rng(10,19) if held; after flip, fast branch (no rng)
        a.tick(now: 1, speakingMode: .idle,
               playerHouseID: Simulation.House.ordos,
               rng: rng.range)
        // After the tick, otherFrame incremented to 1 (non-zero) and
        // the reschedule is 6 ticks (quick flip) since we're now
        // *away* from frame 0.
        #expect(a.otherFrame == 1)
        #expect(a.otherTimer == 7, "now=1 + 6 = 7")
    }

    @Test("Harkonnen other: effectively dormant (18,000-tick reschedule)")
    func otherHarkonnenDormant() {
        var a = MentatAnimator(otherFrameCount: 0)
        a.tick(now: 5, speakingMode: .idle,
               playerHouseID: Simulation.House.harkonnen,
               rng: { _, _ in 0 })
        #expect(a.otherTimer == 18_005)
        #expect(a.otherFrame == 0,
                "otherFrameCount=0 keeps the frame pinned; scene skips the draw")
    }

    // MARK: - RNG integration (BorlandLCG, same as the scene uses)

    @Test("Integrates with BorlandLCG: deterministic across re-runs at same seed")
    func borlandLcgDeterministic() {
        var a1 = MentatAnimator(otherFrameCount: 2)
        var a2 = MentatAnimator(otherFrameCount: 2)
        var rng1 = RNG.BorlandLCG(seed: 42)
        var rng2 = RNG.BorlandLCG(seed: 42)
        for i in UInt32(1)...200 {
            a1.tick(now: i, speakingMode: .speaking,
                    playerHouseID: Simulation.House.atreides,
                    rng: { lo, hi in rng1.range(lo, hi) })
            a2.tick(now: i, speakingMode: .speaking,
                    playerHouseID: Simulation.House.atreides,
                    rng: { lo, hi in rng2.range(lo, hi) })
        }
        #expect(a1 == a2, "same seed must produce identical animator state after N ticks")
    }
}
