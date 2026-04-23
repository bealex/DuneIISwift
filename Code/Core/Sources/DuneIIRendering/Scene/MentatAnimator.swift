import Foundation
import DuneIICore

/// Pure port of OpenDUNE's `GUI_Mentat_Animation` state machine
/// (`src/gui/mentat.c:553..810`). Advances mouth + eye + "other"
/// (Atreides book / Ordos ring) sprite indices on GUI-tick timers.
/// The scene owns three SKSpriteNode overlays and re-reads the current
/// frames each render tick.
///
/// Value-typed + `Sendable` so we can unit-test the cadence against a
/// deterministic RNG without dragging SpriteKit in. Every time base
/// is measured in `g_timerGUI` units (OpenDUNE's 60 Hz GUI clock); the
/// scene's 60 Hz render loop is a 1:1 match.
public struct MentatAnimator: Sendable, Equatable {

    /// Whether the mentat is mid-speech. `.speaking` cycles the mouth
    /// between frames 0..4 on amplitude-driven timers; `.idle` pins the
    /// mouth to frame 0 (closed).
    public enum SpeakingMode: Sendable, Equatable { case idle, speaking }

    /// Current mouth frame in [0..4]. Frame 0 = closed, 1..3 =
    /// half-open, 4 = fully open.
    public var mouthFrame: Int = 0
    /// GUI-tick timestamp at which `mouthFrame` is next eligible to
    /// change. OpenDUNE stores this as an absolute timer.
    public var mouthTimer: UInt32 = 0

    /// Current eye frame in [0..4]. Frame 0 = straight ahead, 1 =
    /// looking left, 2 = looking right, 3 = eyes down / blinking,
    /// 4 = eyes closed.
    public var eyesFrame: Int = 0
    /// OpenDUNE's two-phase eye animation sometimes queues a
    /// "next frame" to land after a short dwell on frame 3 (mid-blink).
    /// 0 = no queued frame.
    public var eyesNextFrame: Int = 0
    public var eyesTimer: UInt32 = 0

    /// House-object animation (Atreides book, Ordos ring; Harkonnen +
    /// Mercenary / Sardaukar / Fremen have no other object). Our port
    /// simplifies OpenDUNE's signed `int16 otherSprite` to an unsigned
    /// alternation between 0 and `otherFrameCount - 1` so the struct
    /// stays safe under `&+`.
    public var otherFrame: Int = 0
    public var otherTimer: UInt32 = 0
    /// Number of distinct `s_mentatSprites[2][*]` frames loaded for
    /// this house. Harkonnen = 0 (no book/ring, `otherTimer` never
    /// fires a draw); Atreides / Ordos = 2 (alternation).
    public var otherFrameCount: Int

    public init(otherFrameCount: Int = 0) {
        self.otherFrameCount = otherFrameCount
    }

    /// Advance the state machine by one GUI tick at absolute time
    /// `now`. `rng` emulates `Tools_RandomLCG_Range(min, max)` — an
    /// inclusive draw in the given range.
    public mutating func tick(
        now: UInt32,
        speakingMode: SpeakingMode,
        playerHouseID: UInt8,
        rng: (_ lo: UInt16, _ hi: UInt16) -> UInt16
    ) {
        advanceOther(now: now, playerHouseID: playerHouseID, rng: rng)
        advanceMouth(now: now, speakingMode: speakingMode, rng: rng)
        advanceEyes(now: now, speakingMode: speakingMode, rng: rng)
    }

    // MARK: - Other object (book / ring)

    private mutating func advanceOther(
        now: UInt32, playerHouseID: UInt8,
        rng: (UInt16, UInt16) -> UInt16
    ) {
        guard otherTimer < now else { return }
        // Bump the other-frame index (flip between 0 and 1 when only
        // two frames are loaded; walk upward when more are available).
        if otherFrameCount > 1 {
            if otherFrame + 1 < otherFrameCount {
                otherFrame += 1
            } else {
                otherFrame = 0
            }
        }
        // House-specific reschedule. Harkonnen effectively never
        // reschedules (the value is larger than any practical scene
        // session); Atreides picks a short random interval every cycle;
        // Ordos flips quickly after a "held" frame (simulating the
        // ring spinning a couple of positions then resting).
        switch playerHouseID {
        case Simulation.House.harkonnen:
            otherTimer = now &+ 18_000            // OpenDUNE `300 * 60`
        case Simulation.House.atreides:
            otherTimer = now &+ 60 &* UInt32(rng(1, 3))
        case Simulation.House.ordos:
            if otherFrame != 0 {
                otherTimer = now &+ 6             // quick flip
            } else {
                otherTimer = now &+ 60 &* UInt32(rng(10, 19))
            }
        default:
            otherTimer = now &+ 18_000
        }
    }

    // MARK: - Mouth

    private mutating func advanceMouth(
        now: UInt32, speakingMode: SpeakingMode,
        rng: (UInt16, UInt16) -> UInt16
    ) {
        switch speakingMode {
        case .speaking:
            guard mouthTimer < now else { return }
            mouthFrame = Int(rng(0, 4))
            switch mouthFrame {
            case 0:
                mouthTimer = now &+ UInt32(rng(7, 30))
            case 1, 2, 3:
                mouthTimer = now &+ UInt32(rng(6, 10))
            case 4:
                mouthTimer = now &+ UInt32(rng(5, 6))
            default:
                break
            }
        case .idle:
            // Keep the mouth closed between speech bursts.
            if mouthFrame != 0 {
                mouthFrame = 0
                mouthTimer = 0
            }
        }
    }

    // MARK: - Eyes

    private mutating func advanceEyes(
        now: UInt32, speakingMode: SpeakingMode,
        rng: (UInt16, UInt16) -> UInt16
    ) {
        guard eyesTimer < now else { return }

        if eyesNextFrame != 0 {
            // Deferred frame from a prior lookup step lands now.
            eyesFrame = eyesNextFrame
            eyesNextFrame = 0
            eyesTimer = now &+ (eyesFrame != 4
                                 ? UInt32(rng(20, 180))
                                 : UInt32(rng(12, 30)))
            return
        }

        let i: Int
        switch speakingMode {
        case .idle:
            let r = Int(rng(0, 7))
            if r > 5 { i = 1 }
            else if r == 5 { i = 4 }
            else { i = r }
        case .speaking:
            if eyesFrame != 0 {
                i = 0
            } else {
                let r = Int(rng(0, 17))
                if r > 9 { i = 0 }
                else if r >= 5 { i = 4 }
                else { i = r }
            }
        }

        if (i == 2 && eyesFrame == 1) || (i == 1 && eyesFrame == 2) {
            // Avoid an ugly direct 1↔2 flip — bounce through 0.
            eyesNextFrame = i
            eyesFrame = 0
            eyesTimer = now &+ UInt32(rng(1, 5))
        } else if i != eyesFrame && (i == 4 || eyesFrame == 4) {
            // Entering or leaving the closed-eyes state always dwells
            // on frame 3 (half-closed) for one tick.
            eyesNextFrame = i
            eyesFrame = 3
            eyesTimer = now
        } else {
            eyesFrame = i
            eyesTimer = now &+ (i != 4
                                 ? UInt32(rng(15, 180))
                                 : UInt32(rng(6, 60)))
        }
    }
}
