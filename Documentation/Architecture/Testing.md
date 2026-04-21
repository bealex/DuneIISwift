# Testing strategy

Status: Drafted 2026-04-19 (P1 lock-in)

This document says *what* is tested, *how* it is tested, and *what coverage each layer must hold* before a feature is considered done. The TDD loop that drives it lives in `CLAUDE.md` under "Feature workflow"; this doc is the architectural complement.

## 1. Layers

| Layer        | Representative module             | Test kind                              |
|--------------|-----------------------------------|----------------------------------------|
| Codec        | `Codec.Format80`, `Codec.Format40`| Synthetic opcode-by-opcode + edge cases.|
| Format       | `Formats.Pak`, `Formats.Shp`, …   | Synthetic round-trip + real-data smoke. |
| Asset export | `AssetExport.PNGWriter`, `WAVWriter`, `Extractors` | Binary-layout assertion + file-layout assertion. |
| Simulation   | `Core.Simulation.*` (P4+)         | Golden snapshot diff vs. OpenDUNE.      |
| Save parity  | `Core.Save.ClassicDat` (P6)       | Byte-identical round-trip over real `_SAVE00?.DAT`. |
| Rendering    | `Rendering.*` (P2+)               | Atlas snapshot test; manual for scenes. |

Every layer sits in `Code/Core/Tests/DuneIICoreTests/`.

## 2. Synthetic vs. real-data tests

Every decoder ships with both, where feasible:

- **Synthetic** — a hand-built byte buffer that exercises one specific behavior. Fast, hermetic, runs on any machine. These are the primary specs.
- **Real-data** — opens a file from `Repositories/patched_107_unofficial/` through `TestInstall.locate()`. Short-circuits when the install isn't present so the suite still runs on a bare CI machine.

Real-data tests must not encode precise byte-level expectations — they assert *invariants* (`pixels.count == w * h`, `tileCount == rtbl.count`, etc.). Precise expectations belong to synthetic tests.

## 3. Golden snapshots (Simulation, P4+)

When `GameActor` arrives, we'll drive it with a canned `GameCommand` script, let it tick N frames, and compare the resulting state against a JSON snapshot checked in under `Code/Core/Tests/Snapshots/`. The reference snapshot is generated once by running OpenDUNE with the same inputs via a small harness, then frozen. Every simulation change must either leave the snapshot untouched *or* ship with the snapshot update in the same commit and a history entry explaining why.

## 4. Save parity (P6+)

We load each of the user's seven real `_SAVE00?.DAT` files, re-serialize through our encoder, and assert **byte-identical** output. Any difference means either (a) our decoder lost a byte, or (b) our encoder added one. Both are hard failures — there is no "close enough" mode.

## 5. Coverage rule

The repo convention is that every branch in a format/codec/simulation module has a test that fires it. Concretely:

- Every `DecodeError` case has a test that throws it.
- Every `if` branch that handles a file-format variant (modern vs. legacy, compressed vs. raw, continuation vs. regular) has a test per branch.
- Every overload of a writer has a test that exercises it and reads the result back.

When you extend a module, the PR that adds behavior must also add the test. CI runs `swift test` from `Code/Core/` and fails on any red.

## 6. Running tests

```
cd Code/Core
swift test                 # full suite
swift test --filter Foo    # Swift Testing filters by suite or test name
```

Real-data tests print nothing when the install is missing — they just pass trivially. If you want to force them, run with the install available or set up a symlink:

```
ln -s /path/to/duneii/install Repositories/patched_107_unofficial
```

## 7. What to do when a test is hard to write

If a feature genuinely can't be tested (e.g. visual correctness of a shader), say so in the history entry and write a manual-verification checklist in the format doc. Don't skip the test silently.
