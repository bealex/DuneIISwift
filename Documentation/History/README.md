# History

Dated changelog of everything that lands in this repo. One file per calendar month, named `YYYY-MM.md`. Each entry is a single dated heading followed by bullets.

## What goes here

- Every feature that ships (new format, new module, new UI screen).
- Every bug fix that changes behavior (not formatting/refactor churn).
- Every plan file that is written or superseded.
- Every non-obvious decision the author made, with a one-line rationale.

## What does *not* go here

- Commit-log noise ("renamed variable", "moved file"). Git already has that.
- Design rationale that belongs in a format doc, insight, or plan.
- TODOs — those belong in a plan or an issue tracker.

## Entry format

```markdown
## YYYY-MM-DD

- Short imperative summary (under 120 chars).
  - Indented detail / rationale when needed, one line.
- Next bullet.
```

One file per month; append to the end of the current month's file as you work. Start a new `YYYY-MM.md` on the first day of a new month. Never rewrite history — if an entry turns out to be wrong, add a new dated correction rather than editing the old one.

## Index

- [2026-04](2026-04.md) — P1 kickoff, format foundation, `assetgen` CLI.
