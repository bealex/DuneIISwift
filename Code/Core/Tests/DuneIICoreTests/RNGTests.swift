import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.RNG")
struct RNGTests {
    // MARK: Tools_Random_256

    @Test("ToolsRandom256(seed: 0) starts from a pinned sequence")
    func toolsRandom256Pinned() {
        var rng = RNG.ToolsRandom256(seed: 0)
        let produced = (0..<5).map { _ in rng.next() }
        #expect(produced == pinnedTools256Seed0)
    }

    @Test("reseeding restarts the stream")
    func reseedRestarts() {
        var rng = RNG.ToolsRandom256(seed: 353)
        let first = (0..<3).map { _ in rng.next() }
        rng = RNG.ToolsRandom256(seed: 353)
        let second = (0..<3).map { _ in rng.next() }
        #expect(first == second)
    }

    @Test("copies are independent streams")
    func copiesIndependent() {
        var a = RNG.ToolsRandom256(seed: 12345)
        var b = a
        let fromA = (0..<5).map { _ in a.next() }
        let fromB = (0..<5).map { _ in b.next() }
        #expect(fromA == fromB)
    }

    // MARK: Borland LCG

    @Test("BorlandLCG(seed: 1) has the classic first five values")
    func lcgFirstFive() {
        var rng = RNG.BorlandLCG(seed: 1)
        // (0x015A4E35 * 1 + 1) = 0x015A4E36 → high u16 = 0x015A → & 0x7FFF = 0x015A = 346
        // iterate 5 steps and compare to a ground-truth reference.
        let produced = (0..<5).map { _ in rng.next() }
        #expect(produced == pinnedLcgSeed1)
    }

    @Test("BorlandLCG.range stays inside [min, max] across many draws")
    func lcgRangeBounded() {
        var rng = RNG.BorlandLCG(seed: 42)
        for _ in 0..<10_000 {
            let v = rng.range(10, 20)
            #expect(v >= 10 && v <= 20)
        }
    }

    @Test("BorlandLCG.range swaps min/max when passed out of order")
    func lcgRangeSwap() {
        var a = RNG.BorlandLCG(seed: 99)
        var b = RNG.BorlandLCG(seed: 99)
        let x = a.range(20, 10)
        let y = b.range(10, 20)
        #expect(x == y)
    }
}

/// Frozen regression baseline — the first five outputs of our
/// Tools_Random_256 Swift transcription when seeded with 0. The
/// algorithm is a line-for-line port of OpenDUNE `src/tools.c`, so
/// this sequence is the same one the C code produces. Cross-check
/// against OpenDUNE once we can link against it, but any change here
/// means a behavior regression.
private let pinnedTools256Seed0: [UInt8] = [0x80, 0xC0, 0xE0, 0xF0, 0xF8]

/// First five outputs of the Borland LCG seeded with 1. Matches the
/// classic `0x015A4E35 * state + 1` sequence.
private let pinnedLcgSeed1: [Int16] = [0x015A, 0x0082, 0x2AE6, 0x0442, 0x2D88]
