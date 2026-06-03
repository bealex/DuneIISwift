# The Mentat help text lives in MENTAT&lt;HOUSE&gt;.ENG, not the stat tables — and it's compressed at raw file offsets

**Finding:** The in-game building/unit/house descriptions the Mentat shows are **not** reachable from the stat
tables. `ObjectInfo.hintStringID` only covers **structures** (341–358 → `MESSAGE.ENG`, local index
`hintStringID − 339`); **every unit has `hintStringID == 0`**. The real Mentat database is `MENTAT<HOUSE>.ENG`
(`ENGLISH.PAK`): an IFF `FORM`/`MENT` whose `NAME` chunk is a packed topic list, with each topic's description
char-pair-**compressed** at an **absolute file offset** named in the entry (not inside an IFF chunk). It carries
its own per-topic campaign gate and groups topics into Houses / Structures / Vehicles / Specials.

**Why it matters:** anyone wanting "the game's own text" for units/houses will look at `hintStringID` and the
`.ENG` string tables and come up empty for units. The text is only in the MENTAT files, and reading it needs
three non-obvious steps: (1) parse the `NAME` entries (`[size][offset BE][section ascii][level ascii][name NUL][campaign]`),
(2) seek to the **absolute** `offset` and decompress until NUL with the `String_DecompressAndTranslate` digram
table (high-bit byte → a 2-char pair via `couples`; `0x1B` escapes `0x7F + next`), (3) split the result
`"<wsa>*<title>\r<attr>…\u{0C}<body>"`. Topic names differ from our `displayName`s ("IX", "Wor", "Combat Tank",
"Light Infantry"), so a name→type map is required to attach sprites/stats.

**Evidence:** decoder `DuneIIFormats/Formats/Mentat/MentatHelp.swift`; UI `DuneIIClient/MentatView.swift` (the
name→`StructureType`/`UnitType` maps); test `FormatsTests/MentatHelpTests`; format doc
`Documentation/Formats/MentatHelp.md`; OpenDUNE `gui/mentat.c` (`GUI_Mentat_LoadHelpSubjects`/`ShowHelp`) +
`string.c:88` (`String_DecompressAndTranslate`). The committed `Resources/Strings/MENTAT*.ENG` mirror the PAK
copies (verified `MENTATH.ENG` is in `ENGLISH.PAK`, which `AssetStore` loads).

**How to apply:** for "real game text", check which file actually holds it before trusting a `*StringID` field —
units route through the MENTAT database, structures through `MESSAGE.ENG`, house lore through `TEXT<HOUSE>.ENG`
(also compressed). The `couples` digram decompressor is shared by all the compressed `.ENG`/MENTAT text; reuse it.
Related: [[host-presentation-gap-not-sim]].
