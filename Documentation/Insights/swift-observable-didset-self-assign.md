# @Observable didSet self-assignment recurses infinitely

**Finding:** Reassigning a property inside its own `didSet` on an `@Observable` class re-enters the synthesized setter, so a clamp like `var x = 1 { didSet { x = min(max(x, 1), 9); … } }` recurses until the stack overflows (the crash shows `campaignLevel.setter` ↔ `_campaignLevel.didset` alternating thousands of frames).

**Why it matters:** It compiles cleanly and tests don't catch it (no test drives the SwiftUI/@Observable setter path) — it only crashes at runtime when the user changes the control. Unlike a plain stored property, the Observation macro's setter has no "skip if unchanged" guard, so even assigning the *same* value loops.

**Evidence:** `Code/Apps/duneii/GameModel.swift:74` (`campaignLevel`'s `didSet`); the crash backtrace was a deep `GameModel.campaignLevel.setter` / `GameModel._campaignLevel.didset` cycle from an `NSPopUpButtonCell` mouse-down.

**How to apply:** Never write the property from its own `didSet`/`willSet`. Clamp/validate at the call sites (or in the SwiftUI `Binding`'s `set:`) instead, and keep `didSet` to side effects on *other* state (e.g. `simulation?.state.campaignID = UInt8(clamping: campaignLevel)`).
