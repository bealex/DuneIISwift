# Split file text with components(separatedBy:), not split(separator:)

**Finding:** `text.split(separator: "\n", omittingEmptySubsequences: false)` returned the entire CRLF text as a single element, so the INI parser saw one giant "line" and found only the first section. `text.components(separatedBy: .newlines)` splits correctly and handles `\n`, `\r`, and `\r\n`.

**Why it matters:** Silent failure — it compiles and "works" on single-line input, then mis-parses real multi-line files. Cost real debugging time.

**Evidence:** `Ini.init(text:)` in `Code/Frameworks/DuneIIFormats/Formats/Ini/Ini.swift`; tests in `Code/Tests/FormatsTests/IniTests.swift`.

**How to apply:** For line-based parsing of file text, use `components(separatedBy: .newlines)` (import Foundation). Reserve `split(separator:)` for cases where the exact overload behavior is well understood.
