# Linting & Formatting

Two tools keep the Swift sources on the project code style (`~/Programming/_Scripts/Instructions/CLAUDE.CodeStyle.md`). Both are driven by wrapper scripts under `Scripts/` and scoped to `Code/` (the engine package); `Repositories/`, `SwiftOPL3/`, `build/`, and `.build/` are excluded.

- `Scripts/format.sh` — rewrites layout. `--check` reports without modifying; takes path args to scope down.
- `Scripts/lint.sh` — reports style violations. `--strict` fails on any finding, `--fix` auto-corrects the correctable ones, takes path args.

## Formatter: swift-format

Config: `Code/.swift-format` (also auto-discovered by editors). It lists only the deviations from swift-format's defaults that the code style requires:

- `indentation: 4 spaces`, `lineLength: 120`.
- `indentSwitchCaseLabels: true` — `case` is indented one level inside the `switch` body (the non-default Swift style the guide mandates).
- `spacesAroundRangeFormationOperators: true` — `0 ..< n`, not `0..<n`.
- `lineBreakBeforeEachArgument: true` — when an argument/parameter list wraps, every item goes on its own line (no partial breaks).
- `NoEmptyLinesOpeningClosingBraces` — no blank line hugging a type's braces.
- Force-unwrap / force-try / IUO / early-exit rewrites left **off**, because the style permits those constructs by design and the formatter must not rewrite them away.

`respectsExistingLineBreaks` (default) is what lets swift-format preserve the project's multi-line `guard` layout (guard alone on its line, expression indented below) instead of reflowing it.

### The SwiftSyntax post-pass: `Code/Tools/StyleRespace`

A few style points are things swift-format actively gets *wrong* for this style and can't be configured out of. `format.sh` runs a second pass — `style-respace`, a small SwiftSyntax tool in its own package (kept separate so the swift-syntax dependency stays out of the engine graph) — that fixes them on the parsed tree. It is idempotent and runs as a stdin→stdout filter (`style-respace -`) so `--check` can pipe `swift-format … | style-respace - | diff`. Three rewriters, applied in order:

1. **Collection-literal spacing** — swift-format normalises literals to tight brackets (`[ .foo ]` → `[.foo]`) with no option to keep the interior spaces the style wants, and a regex can't tell a literal from an array **type** (`[Int]`) or a **subscript** (`arr[0]`). The rewriter re-inserts one interior space on **single-line `ArrayExpr` / `DictionaryExpr` literals only** — types, subscripts, multi-line literals, strings, and comments are different syntax nodes and are left untouched. Never doubles an existing space.

2. **Guard layout** — the codestyle wants a guard on one line when it fits in 120, else `guard` alone with one condition per indented line and `else` on its own line (Options 1–3). swift-format breaks by *length*, not per-condition, and the SwiftLint regex rule can only flag, not fix. The rewriter collapses guards that fit and explodes those that don't, reusing swift-format's already-correct `else`/body. Bails on guards with comments in the condition region or a single multi-line condition.

3. **Ternary layout** — swift-format breaks after the `=` / `return` and drops the condition onto its own line (`let x =` ⏎ `cond` ⏎ `? …` ⏎ `: …`). The codestyle keeps the condition on the line it starts (`let x = cond` ⏎ `? …` ⏎ `: …`), with `?` / `:` indented under it (swift-format already indents those). The rewriter pulls the condition up — but only the ternary's actual condition element, and only in a true right-hand-side position (`let`/`return` value, or after an assignment `=`), so it never swallows a statement separator. Inline ternaries that fit are left alone.

## Linter: SwiftLint

Config: `.swiftlint.yml` (repo root). It owns the lint-only concerns and the few rules that must **agree** with the formatter:

- `switch_case_alignment: indented_cases` and `trailing_comma: mandatory_comma` — kept consistent with swift-format's indented cases and trailing commas.
- Opt-in: `sorted_imports`, `closure_spacing`, `vertical_whitespace_opening/closing_braces`, `multiline_parameters`, `multiline_arguments`.
- Disabled: `todo`, `force_try` (style permits them), and the noisy metric rules (`function_body_length`, `type_body_length`, `cyclomatic_complexity`, `function_parameter_count`, `large_tuple`) — counterproductive on the faithful EMC transcriptions and big stat tables.
- `line_length` warns at 120; `file_length` warns at 1000 (the guide's split-the-file threshold); `identifier_name` min length 1 (the style allows `i`, `id`, `x`, `y`).

### Custom (regex) rules

SwiftLint user rules are regex-only (no AST). Three encode style points the built-ins and swift-format don't cover. All were tuned against the codebase to **0 false positives**; `excluded_match_kinds` keeps the collection rules out of comments and strings.

- `guard_break_keep_guard_alone` — a `guard` that breaks across lines (its line ends in `,`, `{`, `&&`, or `||`) must instead stand alone with the expression indented below. swift-format preserves the correct form but won't auto-fix the broken one, so the linter flags it.
- `collection_literal_open_space` / `collection_literal_close_space` — require the interior spaces (`[ .foo ]`). They key off a literal start (`.`, `"`, or a digit after `[`) so array types and subscripts (which start with / follow an identifier) are never matched. This is the lint side of the `style-respace` formatter pass.

## How the two stay consistent

swift-format strips collection-literal spaces; `style-respace` puts them back; SwiftLint enforces they're present. Running `format.sh` then `lint.sh` on the same file is fixpoint-stable: the formatter's output passes the linter, including the guard and collection-literal rules.
