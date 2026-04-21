# WSA files with `offsets[0] == 0` are continuations of a prior animation

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Wsa/WsaAnimation.swift`
- **Category**: format
- **Applies to**: `Formats.Wsa.Animation`, any cutscene sequencer.

## The fact

Six shipped WSA files — `HFINALC.WSA`, `OFINALB.WSA`, `OFINALC.WSA`, `INTRO7B.WSA`, `INTRO8B.WSA`, `INTRO8C.WSA` — store `offsets[0] == 0`. That doesn't mean "empty frame" or "corrupt"; it means "frame 0 was rendered by the previous WSA in the sequence, keep the display buffer you already have".

## Why it matters

Our decoder used to throw `offsetOutOfRange(index: 0)` for these six files. The fix: when `offsets[i] == 0`, emit the running display buffer as-is (don't format80/format40, don't advance the source) and move on. For standalone decoding — the assetgen use case — this produces a zero frame at index 0, then the rest of the animation plays against it. When we later wire these into the intro sequencer, we'll pass the previous file's last frame as the starting buffer.

## Where it lives in our code

- `Formats.Wsa.decode` — the `if start == 0 { … continue }` branch.
- `Tests/DuneIICoreTests/WsaTests.swift::continuationFile` covers it.

## Where it lives in the reference

OpenDUNE `src/wsa.c::WSA_LoadFile` sets `flags.hasNoFirstFrame = true` when `firstFrameOffset == 0`, and `WSA_GotoNextFrame` silently returns 0 for that frame without XORing anything.
