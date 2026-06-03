import Testing

@testable import DuneIIContracts

@Suite("FrameThrottle")
struct FrameThrottleTests {
    /// The neutral default: interval 1 fires every call, so a consumer that leaves it at 1 behaves exactly
    /// as if there were no throttle (the goldens stay byte-identical).
    @Test func intervalOneFiresEveryCall() {
        var t = FrameThrottle(every: 1)
        for _ in 0 ..< 10 {
            let fired = t.tick()
            #expect(fired)
        }
    }

    /// Fires on calls 0, interval, 2·interval, … — the first call always fires (initial state populates
    /// immediately), then one in every `interval`.
    @Test func firesOnEveryNthCall() {
        var t = FrameThrottle(every: 3)
        let fired = (0 ..< 9).map { _ in t.tick() }
        #expect(fired == [ true, false, false, true, false, false, true, false, false ])
    }

    /// A larger interval rebuilds proportionally less often.
    @Test func countsAcrossManyCalls() {
        var t = FrameThrottle(every: 6)
        let count = (0 ..< 60).reduce(into: 0) { acc, _ in if t.tick() { acc += 1 } }
        #expect(count == 10)  // 60 frames / 6 = 10 fires
    }

    /// Non-positive intervals clamp to 1 (fire every call) rather than dividing by zero / never firing.
    @Test func nonPositiveIntervalClampsToOne() {
        var zero = FrameThrottle(every: 0)
        #expect(zero.interval == 1)
        let zeroFired = zero.tick()
        #expect(zeroFired)
        var negative = FrameThrottle(every: -5)
        #expect(negative.interval == 1)
        let negativeFired = negative.tick()
        #expect(negativeFired)
    }
}
