# Format80 back-references must be copied byte-by-byte

**Finding:** Format80's relative/absolute copy commands routinely reference bytes *inside the span they are currently writing* (offset < size). The copy must run one byte at a time so freshly written bytes feed later reads within the same command — that is exactly how the format encodes runs (e.g. a relative copy with offset 1 replicates the previous byte N times). A bulk / `memcpy` / `Data` range copy reads stale data for the overlap and produces wrong output.

**Why it matters:** An innocent-looking "optimization" that swaps the per-byte loop for a bulk copy silently corrupts every sprite/image/animation frame that uses overlapping back-references — and many do. OpenDUNE's source explicitly avoids `memcpy` for this reason (some platforms route it through `memmove`).

**Evidence:** the `for` copy loops in `Code/Frameworks/DuneIIFormats/Codec/Format80.swift`; the `relativeOverlapRun` test in `Code/Tests/FormatsTests/Format80Tests.swift` (offset 1 → `AAAA`); OpenDUNE `src/codec/format80.c:39-40`.

**How to apply:** Keep the byte-by-byte copy loops for all Format80 back-references, and apply the same caution to Format40 and any other LZ-style codec we port. Never replace them with a range/bulk copy.
