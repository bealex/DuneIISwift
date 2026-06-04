# Project Methodology — Structure, Process, Documentation & Routines

A portable, language-agnostic description of how to run a software project so that any
coding agent (or human) can pick up the work cold, follow a consistent process, and keep
the project's own documentation and tooling current.

This file has two jobs:

1. **Baseline** — Sections 1–4 define a recommended operating model: how the agent-instruction
   file is structured, how the coding process flows, what documentation exists and when it is
   updated, and which routines run on a cadence.
2. **Auditor** — Section 5 is an instruction set. When you hand this file to a coding agent,
   it should compare the *current* project against the baseline, propose concrete changes, let
   the user choose, and then apply the chosen changes.

Nothing here is tied to a language, framework, or domain. Treat every concrete mechanism as a
*role to be filled*, not a literal command — the project may already fill it under a different
name, and that is fine.

---

## 1. The agent-instruction file (the "CLAUDE.md" role)

Every project should have a single, authoritative **agent-instruction file** at the repo root —
the first thing any contributor or agent reads. Its job is to make a cold start possible: what
this project is, where things live, how to work on it, and what never to do.

A good instruction file has these sections, in roughly this order:

1. **One-paragraph identity.** What the project is, who it's for, the platform/runtime targets,
   and the single most important quality bar (the thing correctness is measured against).
2. **Pointer to the live state file.** A loud instruction to read the operational state document
   *first* (see §3, the "current state" role) before doing anything else — *if the project keeps
   one*. This file earns its keep only on long, multi-session tasks (see §3); a project made up of
   small, single-session tasks may not have or need one, and this pointer is then omitted.
3. **Pointer to the plan and the architecture overview.** The authoritative plan of record and the
   topology/dependency-rules reference.
4. **Layout.** A map of the top-level directories and key files, each with a one-line purpose.
   This is the table of contents for the repo. Keep module/component boundaries and their
   dependency direction explicit here.
5. **Core principles.** A short numbered list of the non-negotiable invariants — the rules that,
   if violated, make the work wrong regardless of whether it "works." (Determinism, a single
   source of truth for state, a named oracle/reference for correctness, dependency direction, etc.)
6. **Conventions.** Style, structure, and idiom rules; where each kind of thing lives; what shape
   new components take. Link out to a shared style guide rather than inlining it.
7. **The feature workflow.** The numbered, mandatory step sequence for landing a change (see §2).
8. **Verification bar — "what counts as done/tested."** The concrete definition of sufficient
   testing and proof, including the project's *golden/acceptance* artifact per feature where one is
   feasible (see §2 — goldens are expected when achievable, optional when genuinely not).
9. **Running things.** The wrapper scripts / entry points for the routine checks, with a one-line
   description of each, plus the raw commands they wrap as a fallback.
10. **What *not* to do.** An explicit anti-pattern list — the mistakes that have actually bitten
    this project, phrased as prohibitions.

**Principles for the instruction file itself:**

- It is **operational, not aspirational** — every rule should be actionable and checkable.
- It **overrides defaults**: state plainly that these instructions take precedence over an agent's
  default behavior.
- It is **layered**: a top-level file for whole-project rules, and optionally a smaller instruction
  file per module/component for local rules. Local files never contradict the root.
- It is **maintained**: when a convention changes, the file changes in the same commit.

---

## 2. The coding process

The process is a fixed, ordered **feature workflow**. The point is that no step is silently
skipped — each produces a visible artifact (a doc, a test, a log line, a state update).

A complete feature workflow looks like this:

0. **Orient.** *(optional — only when a live state file exists.)* If the project keeps a live state
   file (see §3), open it; confirm the task matches the active/queued work, and if it's new, record
   it there first so a cold reader could resume. For a small, self-contained task with no state file,
   skip this step entirely — just make sure you understand the goal.
1. **Design on paper first.** Write or update the relevant design/format/algorithm doc *before*
   writing code — in your own words, with a pointer to the reference source if one exists.
2. **Implement.** Build exactly what's needed. No abstractions for hypothetical futures; no
   speculative generality. Required structural seams are not speculation — build those.
3. **Test the new behavior.** Tests come *after* the implementation (unless the project explicitly
   mandates test-first). Prefer synthetic/deterministic inputs; add a real-data/oracle test when
   one can exercise the path.
4. **Run the full check.** Build + full test suite must be green before "done." Every
   previously-green test stays green.
5. **Zero warnings on a clean build.** A clean rebuild must be warning-free; treat every warning as
   a failure and fix the root cause. Read the *full* build output, not a filtered tail.
6. **Log the change.** Append a one-line, imperative changelog entry (see §3, the history role),
   with references to the files touched.
7. **Update the living state and status tables.** *If the project keeps a live state file* (see §3),
   move the finished item to "recently completed," set the next active task with its immediate next
   step, and refresh the test status. Either way, update any living "done/not-done" feature table the
   change affected.
8. **Capture insights.** If you learned something non-obvious, record it as a standalone insight
   (see §3) and index it.

**Which steps are mandatory** should be stated explicitly in the instruction file (typically 1 and
3–6 are non-negotiable). Steps **0** and the state-file half of **7** are conditional — they apply
only when the project keeps a live state file (see §3); skip them otherwise. Step **8** is
conditional on having learned something worth capturing.

**The verification bar (the "golden" rule).** Where it's achievable, unit tests alone do not close a
feature — it should also produce a durable **acceptance artifact** appropriate to its kind:

- behavior/logic work → a cross-checked golden against the reference/oracle;
- presentation/output work → a snapshot/output golden;
- work with no external oracle (a debug toggle, a pure-UI seam) → a *neutrality* golden proving the
  existing goldens stay identical with the feature off, **plus** unit coverage — and the History
  entry must say so explicitly.

**Goldens are optional when they're genuinely not feasible.** Not every project or feature admits a
stable acceptance artifact — there may be no reference/oracle to check against, the output may be
inherently non-deterministic or non-capturable, or the cost of pinning it may exceed its value. When
that's the case, don't force a brittle one: fall back to the strongest verification available (unit
and integration tests, manual-verification checklists, etc.) and **state in the History entry that a
golden wasn't feasible and why.** The rule is "produce a golden where one is possible and worthwhile,"
not "every feature must have a golden no matter what." A project may reasonably have no golden
infrastructure at all if its domain doesn't support one.

**Commit & check cadence.**

- Commit after every 2–3 logical work-units (or after each phase), not one tiny increment per commit.
- For repetitive batched work, relax per-step checks to match: a batch's own new/changed tests must
  pass every batch; run the *full* suite every 4–6 batches; do a *clean* build every 6–10 batches;
  always finish with a full suite + clean build before declaring done.
- Use the project's standard commit-message trailer/convention.

**Standing prohibitions** (generalize from the project's own "what not to do"):

- Don't create branches, push, or publish outward unless explicitly told to.
- Don't "improve," rebalance, or rewrite behavior whose correctness is defined by a reference —
  faithful transcription is the bar, not your better idea.
- Don't edit generated artifacts by hand — regenerate them.
- Don't introduce global mutable state or cross-layer coupling that the architecture forbids.
- Don't rewrite historical changelog entries — append a dated correction instead.

---

## 3. Documentation structure

Documentation is split by *purpose and lifetime*. Each kind answers a different question and has its
own update trigger. The key insight: **some docs are operational (change constantly), some are
authoritative (change deliberately), and some are append-only (never rewritten).**

| Role | Question it answers | Lifetime | Update trigger |
|------|--------------------|----------|----------------|
| **Live state** *(long tasks only)* | "Where are we *right now*?" | Operational | After **every** task |
| **Plan of record** | "What are we building and in what order?" | Authoritative | When goals/phases change |
| **Architecture overview** | "How is the system shaped, and what are the rules?" | Authoritative | When topology/dependency rules change |
| **Reference docs** | "How does this format/algorithm/subsystem work?" | Authoritative | Before implementing that thing (design-first) |
| **Living status tables** | "What's done vs. not, feature by feature?" | Authoritative | Whenever a feature's status moves |
| **History / changelog** | "What changed, when?" | Append-only | After every change (workflow step 6) |
| **Insights** | "What non-obvious thing did we learn?" | Append-only | When something surprising is discovered |

**The live state file** is the operational resume point: the active task, what was in flight, the
ordered queue of next steps, and the current test/health status. When it exists, it is read *first*
and updated *last* in every task, and a cold reader should be able to resume from it.

**This file is only warranted for long, multi-session work** — a task large enough that a session may
end (or context may be lost) mid-way and need to be picked up later from a cold start. That is the
problem it solves: surviving restarts. For a project (or a phase) made of **small, single-session
tasks** that each start and finish within one sitting, a live state file is unnecessary overhead and
should be skipped — the changelog (history) already records what was done, and the plan records
what's next. Adopt the live state file when tasks routinely outlive a session; drop it when they
don't. When it's absent, workflow steps 0 and 7 simply don't apply.

**The plan of record** holds goals, locked decisions, and the phased build order. It changes
deliberately, not casually.

**The architecture overview** holds the system topology, the dependency-direction rules, and any
hard external constraints. It's the place to check before adding a component or a dependency.

**Reference docs** (one per format/algorithm/subsystem) are written *before* the corresponding code,
in the project's own words, each pointing at its source of truth. This is the design-first artifact
from workflow step 1.

**Living status tables** track feature-by-feature done/not-done against the reference. A change that
moves a feature's status but doesn't update the table is incomplete.

**History** is a dated changelog, one file per active day, newest-first index, append-only. Never
rewrite an entry; add a dated correction.

**Insights** are distilled, non-obvious findings — one fact per file, indexed, cross-linked to the
code and test that prove them. They exist so the same surprise isn't rediscovered twice.

**Documentation principles:**

- Design docs are written **before** the code they describe.
- Operational docs are updated **after** every task; authoritative docs **when the decision changes**.
- Append-only docs are **never rewritten** — corrections are additive and dated.
- Every doc states its **source of truth** when it has an external one.
- Cross-link liberally: code ↔ test ↔ insight ↔ history.

---

## 4. Regular routines

Routines are the repeatable actions of each work cycle, encapsulated as **scripts/entry points** so
nobody re-types environment-specific incantations and everyone gets the same distilled output. The
script directory (or task runner) is the single source of truth for "the regular actions each round."

The routines that should exist, by role:

- **The standard check** — incremental build + full test suite, distilled to a concise
  pass/fail-with-reasons summary. The default inner-loop command.
- **The full/clean check** — a from-scratch rebuild for the zero-warnings audit (workflow step 5).
- **The focused check** — build + only the matching subset of tests, for a fast inner loop. (Watch
  for footguns here — e.g. a filter that silently matches nothing and reads as a false green; the
  instruction file should warn about any such trap.)
- **The changelog appender** — one command that adds a History bullet (and creates/indexes a new day
  file when needed), so logging is frictionless (workflow step 6).
- **Reference/oracle rebuild** — if correctness is checked against an external reference, a script to
  rebuild/refresh it.
- **Golden/acceptance regeneration** — a script to regenerate the acceptance artifacts (all, or one).
- **Investigation helpers** — the source-reading / disassembly / inspection probes that recur every
  work slice, wrapped so they're one command instead of ten.
- **Cross-target / cross-platform checks** — if the project ships to more than one target, a script
  per target that the normal build wouldn't otherwise exercise.

**Routine principles:**

- **Wrap, don't re-type.** When you catch yourself repeating a manual step round after round — a new
  check, an output parse, a probe — fold it into the standard check or add a focused sibling script.
- **Distill output.** A routine should answer "what's wrong" concisely, not dump raw logs.
- **Keep them current.** The script directory is the source of truth for the regular actions; update
  it instead of re-deriving commands in your head.

**Periodic self-review** is itself a routine: on a cadence (after each phase, or every N commits —
whichever comes first), reread the recent History and Insights, and extract any *recurring* problem
or important lesson into a new standing instruction or insight. If nothing recurrent emerges, add
nothing — don't manufacture rules. Track the last review point (e.g. a commit hash) somewhere
durable — the live state file if one exists, otherwise the changelog or the instruction file.

---

## 5. Auditor instructions — for the agent reading this file

You have been given this file to **audit a project's methodology and bring it up to baseline**. Work
in four phases. Do not make changes before the user has chosen them.

### Phase A — Discover

Survey the project as it actually is. Determine, for each of §1–§4, what already exists and where:

- **Instruction file:** Is there a root agent-instruction file? Which of the §1 sections does it
  have? Are there per-module instruction files? Do any contradict the root?
- **Process:** Is there a defined feature workflow? Are the mandatory steps stated? Is there a
  verification bar — and, *where the domain supports one*, a golden/acceptance mechanism? (If goldens
  aren't feasible for this project, their absence isn't a gap; a strong test suite + checklists is.)
  A commit/check cadence? A standing-prohibitions list?
- **Documentation:** Which of the §3 roles exist (live state, plan, architecture, reference docs,
  status tables, history, insights)? Where are they? Are their update triggers stated? For the **live
  state file**, first judge whether the project even needs one — it's warranted only when tasks
  routinely span multiple sessions. If tasks are small and single-session, a missing state file is
  *correct*, not a gap; if tasks are long-running and there's none (or it's stale and out of sync
  with recent commits), that *is* a gap.
- **Routines:** Which of the §4 routines exist as scripts/entry points? Is there a self-review
  cadence? Is output distilled?

Read the real files — don't assume. Note what's present, what's missing, what's stale (e.g. a state
file that doesn't match recent commits, a status table that contradicts the code), and what exists
under a *different name but the same role* (count that as present).

### Phase B — Propose

Produce a gap report: a concise table or list mapping each baseline element to **Present / Partial /
Missing / Stale**, with a one-line evidence note (a path, or what's wrong) for each. Then propose a
**short, prioritized set of concrete changes** — each one specific and actionable (the exact file to
create or edit, and the exact addition/fix), ordered by impact. Prefer filling missing *roles* and
fixing *stale* operational docs over cosmetic restructuring. Respect what the project already does
well — adapt the baseline to the project's existing names and tools rather than imposing new ones.

### Phase C — Choose

Present the proposed changes to the user and let them select which to apply (offer them as a
checklist; recommend a default set). Ask before doing anything destructive or far-reaching. If a
proposed change would contradict an existing explicit project convention, surface the conflict rather
than silently overriding it.

### Phase D — Apply

Apply only the chosen changes. For each:

- Create or edit the real file(s); keep edits minimal and in the project's existing voice and format.
- Don't rewrite append-only history; add, don't overwrite.
- Don't fabricate content for operational docs you can't ground — if you can't determine the current
  active task, ask rather than invent.
- After applying, summarize what changed and what the user should verify, and (if the project logs
  history) add a changelog entry for the methodology update itself.

**Throughout:** treat every mechanism in §1–§4 as a *role to fill*, not a literal command to copy.
The goal is a project where a cold reader can orient from the live state file, follow a consistent
workflow, find documentation matched to its purpose and lifetime, and run every routine check from a
maintained set of entry points — by whatever names this project already uses.
