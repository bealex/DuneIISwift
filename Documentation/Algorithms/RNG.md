# RNG — `Tools_Random_256` and the Borland LCG

Status: Drafted 2026-04-20

Dune II uses two pseudo-random number generators. Matching them bit-for-bit is non-negotiable: the bloom RNG, sandworm movement, initial map generation, and AI decision tie-breakers all draw from `Tools_Random_256`, so any divergence here cascades into non-reproducible gameplay.

References:

- OpenDUNE `src/tools.c` · `Tools_Random_Seed`, `Tools_Random_256`, `Tools_RandomLCG_Seed`, `Tools_RandomLCG_Range`.
- Our implementation: `Core.RNG` in `Code/Core/Sources/DuneIICore/RNG/`.

## 1. `Tools_Random_256`

4-byte state (3 used). Per call, produces a `UInt8`.

```
state[0..3] (a,b,c,d), only a,b,c mutate.

val16 = (b << 8) | c                         // existing 2-byte word
val8  = ((val16 ^ 0x8000) >> 15) & 1         // carry-in bit (sign flip of val16)
val16 = (val16 << 1) | ((a >> 1) & 1)        // rotate bit from a into c:b
val8  = (a >> 2) - a - val8                  // three-term subtraction in u8 modulo
a     = (val8 << 7) | (a >> 1)               // new a = high bit val8 + rotated old a
b     = val16 >> 8
c     = val16 & 0xFF

return a ^ b
```

All arithmetic is modulo 256 for `val8` and modulo 65536 for `val16`. Seed init loads the 32-bit seed into a,b,c,d LSB-first. `d` is never read in the current decompile but kept for save compatibility (it survives in `_SAVE00?.DAT`).

## 2. Borland LCG

Used for menu animations, intro timings, and anywhere OpenDUNE called `rand()`. Not load-bearing for save parity but we implement it for completeness.

```
state = 0x015A4E35 * state + 1
return (state >> 16) & 0x7FFF
```

Range form:

```
value = Int32(lcg()) * (max − min + 1) / 0x8000 + min
```

OpenDUNE loops when `value > max` to avoid bias on uneven ranges.

## 3. Swift API

```swift
public struct RNG {
    public struct ToolsRandom256 {
        public init(seed: UInt32)
        public mutating func next() -> UInt8
    }
    public struct BorlandLCG {
        public init(seed: UInt16)
        public mutating func next() -> Int16
        public mutating func range(_ min: UInt16, _ max: UInt16) -> UInt16
    }
}
```

Both are value types — copies are independent streams, mirroring how OpenDUNE's global state is conceptually single-writer.

## 4. Testing

`Core/Tests/DuneIICoreTests/RNGTests.swift`:

1. `ToolsRandom256(seed: 0)` yields a pinned first five values (frozen from a reference run of the C code).
2. Reseeding re-starts the sequence.
3. `BorlandLCG(seed: 1)` yields a pinned five values.
4. `BorlandLCG.range(10, 20)` always returns a value in `10...20` over 10_000 calls.
