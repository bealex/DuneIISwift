# MENTAT&lt;HOUSE&gt;.ENG — the Mentat help database

The per-house advisor's help content: the topic list (Houses / Structures / Vehicles / Specials) and every
topic's description. Three files, one per playable house, in `ENGLISH.PAK`: `MENTATH.ENG` (Harkonnen),
`MENTATA.ENG` (Atreides), `MENTATO.ENG` (Ordos). Decoded by `DuneIIFormats/Formats/Mentat/MentatHelp.swift`.
Reference: OpenDUNE `src/gui/mentat.c` (`GUI_Mentat_LoadHelpSubjects`, `GUI_Mentat_ShowHelp`) + `src/string.c`
(`String_DecompressAndTranslate`).

## Container

An IFF `FORM` of type `MENT` (see [Iff.md](Iff.md)). The relevant chunk is `NAME` — a packed list of topic
entries. The description **text is not in a chunk**: each entry names an absolute file offset where its
compressed description begins.

## NAME entry

Variable length, back-to-back, until the chunk ends:

| Offset | Size | Meaning |
|--------|------|---------|
| 0 | 1 | `size` — total bytes of this entry |
| 1–4 | 4 | `offset` (**big-endian**) into the whole file — start of this topic's compressed description |
| 5 | 1 | `section` — ASCII `'1'` Houses, `'2'` Structures, `'3'` Vehicles, `'4'` Specials, `'0'` Briefing/Advice/Orders |
| 6 | 1 | `level` — ASCII `'0'` = a section header row, `'1'` = a real topic |
| 7 … | n | `name` — NUL-terminated display name (`"Construction Yard"`, `"Combat Tank"`, `"House Atreides"`) |
| size−1 | 1 | `campaign` — the topic appears once `campaignID + 1 >= campaign` (so `Heavy Factory` = 4 shows from campaign level 3) |

## Description text

Starting at `offset`, bytes are char-pair **compressed** and run until a `NUL`. After decompression the text is:

```
<wsa>*<title>\r<attr>\r<attr>…\u{0C}<body paragraph>
```

- `<wsa>` — the animation filename shown in the original Mentat (e.g. `Construc.wsa`), before the `*`.
- `<title>` and the `\r`-separated `<attr>` lines form the header block (e.g. `Self-Powered`, `Power Output: 100`,
  `Mobility: Tracked`).
- `\u{0C}` (form-feed) separates the header from the body paragraph.

## Char-pair compression (`String_DecompressAndTranslate`)

Per source byte `c`:
- **High bit set** (`c & 0x80`): a 2-char pair. `c &= 0x7F`; emit `couples[c >> 3]` (1st char, 1 of 16) then
  `couples[c + 16]` (2nd char). The 144-byte `couples` table is a fixed digram table (16 first-chars, then 8
  second-chars per first-char).
- **`0x1B`**: escape — the next byte `b` yields literal `0x7F + b` (for codes above 0x7F).
- otherwise: literal byte.

The same scheme compresses the `.ENG` string tables (`TEXT<HOUSE>.ENG`); the uncompressed tables
(`DUNE.ENG`/`MESSAGE.ENG`) skip it. (Structure build-hints live in `MESSAGE.ENG` at local index
`hintStringID − 339`; the Mentat uses the richer descriptions here instead.)

## Notes

- Topic names differ from our `displayName`s (`"IX"` vs House of IX, `"Wor"` vs WOR, `"Combat Tank"` vs Tank),
  so the client maps name → `StructureType`/`UnitType` explicitly (`MentatView.swift`) for the sprite + stats.
- Specials/houses (`Death Hand`, `Fremen`, `House Atreides`) have descriptions but no buildable sprite.
