import Testing

@testable import DuneIIWorld

/// The opt-in RNG draw recorder used to trace-align our streams against the OpenDUNE oracle.
@Suite("RNG trace sink")
struct RngTraceSinkTests {
    @Test("records each Random256 / RandomLCG draw with the current tick, and is free when off")
    func recordsDraws() {
        var r = Random256(seed: 0x1234)
        var l = RandomLCG(seed: 0x1234)
        // Off by default → no recording, value unchanged vs an untraced copy.
        var plain = Random256(seed: 0x1234)
        #expect(r.next() == plain.next())

        let sink = RngTraceSink()
        r.traceSink = sink; l.traceSink = sink
        sink.setTick(5)
        let a = r.next(); let b = r.next()
        sink.setTick(6)
        let c = l.range(0, 10)

        #expect(sink.r256.map(\.value) == [ UInt16(a), UInt16(b) ])
        #expect(sink.r256.allSatisfy { $0.tick == 5 })
        #expect(sink.lcg == [ RngTraceSink.Draw(tick: 6, value: c) ])
    }

    @Test("parses an oracle trace and pinpoints the first divergence")
    func diffPinpoints() {
        let oracleText = """
            tick=1 idx=0 byte=0x13 ctx=NULL
            tick=6 idx=1 byte=0xC2 ctx=u22
            tick=6 idx=2 byte=0xF6 ctx=u22
            """
        let oracle = RngTraceSink.parseOracleTrace(oracleText)
        #expect(oracle.count == 3)
        #expect(oracle[1] == RngTraceSink.OracleDraw(tick: 6, idx: 1, value: 0xC2, ctx: "u22"))

        // Identical stream → no divergence.
        let good = [ RngTraceSink.Draw(tick: 1, value: 0x13), .init(tick: 6, value: 0xC2), .init(tick: 6, value: 0xF6) ]
        #expect(RngTraceSink.firstDivergence(ours: good, oracle: oracle, label: "r256") == nil)

        // A MISSING first draw (our team-cursor-bug shape): everything shifts → diverges at #0.
        let missing = [ RngTraceSink.Draw(tick: 6, value: 0xC2), .init(tick: 6, value: 0xF6) ]
        let msg = RngTraceSink.firstDivergence(ours: missing, oracle: oracle, label: "r256")
        #expect(msg != nil)
        #expect(msg!.contains("#0"))
        #expect(msg!.contains("ctx=NULL"))  // points at the phase-level draw we skipped
    }

    @Test("parses LCG (value=) trace lines too")
    func parsesLCG() {
        let oracle = RngTraceSink.parseOracleTrace("tick=1 idx=0 value=0 ctx=u23\ntick=6 idx=1 value=3 ctx=u22")
        #expect(oracle.map(\.value) == [ 0, 3 ])
        #expect(oracle[0].ctx == "u23")
    }
}
