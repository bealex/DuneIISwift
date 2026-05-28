# INI (scenario / config text)

The text format for scenarios (`SCEN*.INI`) and config. Reference: OpenDUNE `Ini_GetString` / `Ini_GetInteger` (`src/ini.c:14`). Port: `Code/Frameworks/DuneIIFormats/Formats/Ini/Ini.swift`. Tests: `Code/Tests/FormatsTests/IniTests.swift`.

## Semantics

Sections are `[Name]` at a line start; entries are `key=value`. Section names and keys are **case-insensitive**; values run from after `=` to end of line and are trimmed; there is **no comment syntax**. Integers parse with C `atoi` semantics (leading sign/space, digits until non-digit, 0 on garbage). Multi-value fields (e.g. map cells `flags,tileID`) are returned as the raw string and split by callers on `,` / CR / LF. `Ini` parses once into ordered sections and offers `string` / `integer` / `keys` / `sectionNames`.

See insight `swift-string-split` — line-splitting uses `components(separatedBy: .newlines)`, not `split(separator:)`.
