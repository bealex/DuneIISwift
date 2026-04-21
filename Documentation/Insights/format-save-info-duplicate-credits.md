# `INFO` chunk stores `g_playerCreditsNoSilo` twice

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Formats/Save/SaveInfo.swift`
- **Category**: format
- **Applies to**: `Formats.Save.Info`, any future save-writer that reproduces 1.07 byte layout

## The fact

OpenDUNE's `s_saveInfo` table in `src/saveload/info.c` references `g_playerCreditsNoSilo` at two entries — once right after the nested `g_scenario` block (payload offset 228) and again 36 bytes later (payload offset 266). Both entries point at the same global. The live engine simply writes the current credits value twice on save and overwrites the same global twice on load, so the second value always wins. There is no "stable" and "working" credit variant; it's just a duplicate.

## Why it matters

A decoder that assumes each offset is a distinct field will invent a ghost field (and likely name it wrong — "creditsAtSaveStart"? "reserveCredits"?). Anyone round-tripping a save that was edited externally must write the same value to *both* slots, or they'll load with a silent 2-byte miscount depending on byte order. The duplicate is a 2-byte cost, not a feature — surface a single `playerCreditsNoSilo` field in any model and read/write both slots with identical bytes.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Formats/Save/SaveInfo.swift` — decodes the first slot, discards it, then reads the second slot into `playerCreditsNoSilo`. Named constants + a comment at the duplicate-read site call out the quirk.
- `Code/Core/Tests/DuneIICoreTests/SaveInfoTests.swift:duplicateCreditsSecondWins` — pins the "second wins" behaviour on a synthetic body.

## Where it lives in the reference

- OpenDUNE `src/saveload/info.c:126–142` — both `SLD_GENTRY (SLDT_UINT16, g_playerCreditsNoSilo)` entries sit in `s_saveInfo`.
- OpenDUNE `src/saveload/saveload.c:49–208` — the generic table walker; reading the same global twice simply assigns twice.
