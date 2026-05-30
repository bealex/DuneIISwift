# Swift Testing: a `mutating` call can't go inside `#expect`/`#require`

**Finding:** `#expect(state.someMutatingMethod(...))` / `try #require(state.someMutatingMethod(...))` fails to compile when `someMutatingMethod` is `mutating` on a `var` value type — the macro expands the argument into a closure that captures the value **immutably**, so you get `error: cannot use mutating member on immutable value: '$0' is immutable`. (Worse: in this repo's check pipeline it surfaces late as a test-target `error: fatalError`/link failure, not an obvious compile error at the line.)

**Why it matters:** it's easy to write `#expect(s.teamCreate(...))` / `#expect(s.structureSetRepairingState(slot, state: 1))` — and lose time chasing a confusing "fatalError"/missing-symbol message instead of the real cause.

**How to apply:** call the mutating method into a `let` first, then assert the result:
```swift
let slot = s.teamCreate(...)            // call the mutating method here
#expect(s.teams[try #require(slot)]...) // assert on the result / resulting state
// or:
let acted = s.structureSetRepairingState(slot, state: 1)
#expect(acted)
```
Reading immutable state inside `#expect` is fine (`#expect(s.teams[slot].action == …)`); only the *mutating call* must be hoisted out.

**Evidence:** hit twice — `Code/Tests/WorldTests/TeamCreateTests.swift`, `Code/Tests/WorldTests/StructureStateTests.swift`.
