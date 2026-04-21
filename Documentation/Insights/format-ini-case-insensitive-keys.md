# Dune II INI lookup is case-insensitive; storage preserves case

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Ini/IniDocument.swift`
- **Category**: format
- **Applies to**: `Formats.Ini.Document`, future scenario/region/CHOAM loaders.

## The fact

OpenDUNE's `Ini_GetString` uses `strncasecmp` for both section and key matching. Real shipped files mix cases freely — `[BASIC]` next to `[Atreides]`, `LosePicture=` next to `Bloom=` — and the game never bats an eye. When a key appears twice in the same section, the decoder effectively returns the *last* value because it keeps scanning until end-of-section and overwrites the result on every match.

Our decoder therefore:

- Lowercases both sides for comparison, but keeps the original casing in `Entry.key` / `Section.name` so a round-trip encoder (future) can preserve the file verbatim.
- Uses `entries.last(where:)` for typed accessors so duplicate keys behave the same way OpenDUNE does.

## Why it matters

Subtle silent bugs if you use `Dictionary<String, String>` internally: the first assignment wins, not the last, and lookups by the "wrong case" miss. Unit overlays and spawn overrides can rely on duplicate keys (test scenarios in community mods do).

## Where it lives in our code

- `Formats.Ini.Section.value(forKey:)` — case-insensitive, last-wins.
- `Tests/DuneIICoreTests/IniTests.swift::duplicateKeys` proves last-wins.
- `::minimal` proves case-insensitive lookup.

## Where it lives in the reference

OpenDUNE `src/ini.c::Ini_GetString` — the `for (...) { ... strncasecmp ... continue; }` loop re-assigns `ret = current` on every match.
