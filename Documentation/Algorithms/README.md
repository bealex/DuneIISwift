# Algorithms

Per-subsystem algorithm notes. Each file explains *how* a subsystem works in enough detail that a competent engineer could reimplement it without reading the reference C source.

## Expected content (populated as phases ship)

- `Format80.md` — opcode-by-opcode decode trace with a worked example.
- `Format40.md` — XOR-delta opcode trace.
- `EMC.md` — stack-based VM, opcode table, per-entity tick semantics (P4).
- `Pathfinding.md` — harvester / combat unit movement; the original waypoint heuristic (P4).
- `RNG.md` — OpenDUNE's `Tools_Random_?` PRNG; spice bloom + sandworm determinism (P3/P4).
- `SaveFormat.md` — chunk-by-chunk breakdown of `_SAVE00?.DAT`, with the round-trip contract (P6).

## When to write one

When a format doc spills into "how the game *uses* this" territory. The format doc owns the bytes; the algorithm doc owns the semantics that consume them.
