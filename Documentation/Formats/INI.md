# INI — scenario and region config

Status: Documented 2026-04-19

Dune II uses a conventional `.INI` format for every piece of configuration that isn't a binary table: scenarios (`SCEN?00?.INI`), region maps (`REGION?.INI`), and the CHOAM marketplace (`CHOAM.INI`). Our parser produces a neutral `Formats.Ini.Document`; higher-level loaders (coming in P3) will interpret the well-known sections.

References:

- OpenDUNE `src/ini.c` · `Ini_GetString` defines the canonical parsing semantics (case-insensitive keys, line-oriented, no nesting).
- Our decoder: `Formats.Ini.Document` in `Code/Core/Sources/DuneIICore/Formats/Ini/`.

## 1. Syntax

- Sections open with `[Name]` on a line by itself. Everything until the next `[...]` belongs to the section.
- `key=value` pairs live inside sections. The value runs from the character after `=` to the end of the line and is trimmed.
- A line that starts with `;` (after leading whitespace) is a comment.
- Blank lines are ignored.
- Line endings: CR/LF or bare LF.
- Section and key names are **case-insensitive** — OpenDUNE uses `strncasecmp`, and real files mix cases (`[Atreides]` vs `[BASIC]`).
- Values are verbatim ASCII; whitespace at the edges is trimmed.

Worked example (`SCENA001.INI`):

```ini
; Scenario 1 control for house Atreides.

[BASIC]
LosePicture=LOSTBILD.WSA
WinPicture=WIN1.WSA
BriefPicture=HARVEST.WSA
TimeOut=0

[MAP]
Field=1300,1510
Bloom=2409
Seed=353

[Atreides]
Quota=1000
Credits=1000
Brain=Human
MaxUnit=25

[UNITS]
ID038=Ordos,Soldier,256,1246,64,Ambush
ID037=Ordos,Soldier,256,1384,64,Ambush
```

`[UNITS]` and `[STRUCTURES]` list entities with a sequential `IDnnn=` key and a comma-separated field list. Iteration order within a section matters for the game's placement logic; our parser preserves insertion order.

## 2. What the parser is *not* responsible for

- Interpreting field lists ("Ordos,Soldier,256,…"). That's the job of the scenario loader in `Core/Simulation/Scenario/` (P3).
- Normalising key casing. Lookups are case-insensitive, but the keys round-trip in their original case.
- Writing INI back out. We may add an encoder in P3/P5 when save flows need it; for now we're read-only.

## 3. Swift API

```swift
let data = pak.body(named: "SCENA001.INI")!
let doc = try Formats.Ini.Document.decode(data)

// Case-insensitive section + key lookup
let losePicture = doc["basic"]?.value(forKey: "LosePicture")  // "LOSTBILD.WSA"
let credits = doc["Atreides"]?.integerValue(forKey: "Credits") // 1000

// Ordered iteration
for (key, value) in doc["UNITS"]?.entries ?? [] {
    // process key = "ID038", value = "Ordos,Soldier,256,1246,64,Ambush"
}
```

Typed conveniences: `integerValue(forKey:)`, `integerListValue(forKey:)` (for `Field=1300,1510`-style values).

## 4. Testing

`Core/Tests/DuneIICoreTests/IniTests.swift`:

1. Synthetic minimal doc: two sections, each with two keys. Lookup respects case-insensitivity.
2. Comments (`;`) and blank lines are skipped without breaking subsequent sections.
3. CRLF and LF line endings both parse.
4. `integerValue` and `integerListValue` coerce correctly; invalid strings return `nil`.
5. Duplicate keys within a section: the last wins on typed accessors (matches OpenDUNE's "loop until match" behavior).
6. `entries` preserves insertion order for iterable sections like `[UNITS]`.
7. Real `SCENA001.INI` from `SCENARIO.PAK` decodes and has all the expected top-level sections.

## 5. Related insights

- [format-ini-case-insensitive-keys](../Insights/format-ini-case-insensitive-keys.md) — lookup is case-insensitive but storage preserves case.
