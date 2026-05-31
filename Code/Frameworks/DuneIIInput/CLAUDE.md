# DuneIIInput

Input. Depends only on `DuneIIContracts` (the `Command` vocabulary). Never depends on the simulation.

The `input → sim` driver. An `InputSource` produces `Command`s the host applies between ticks; input never mutates simulation state directly.

Present (first version):
- **`InputSource`** protocol — `drainCommands() -> [Command]`.
- **`ScriptedInput`** — a fixed `Command` list (headless test scenarios / scripted playback; the determinism hook for parity runs).
- **`Selection`** — presentation-local selection (`.none`/`.unit(slot:)`/`.structure(slot:)`); a unit/structure is named by its **pool slot**, the same identifier a `Command` carries. The sim has no "selected" concept.
- **`InputController`** — the interactive selection + order state machine (a pure, unit-testable value type, also an `InputSource`). The host resolves a clicked tile to the entity there (it needs the world model: `unitGetByPackedTile`/`structureGetByPackedTile`) and feeds the controller `leftClick`/`rightClick` (+ the `enemyTarget` flag) and inspector-button actions (`beginOrder`/`stopSelected`/`deselect`); the controller tracks the `selection` + an armed `pendingOrder` and queues `move`/`attack`/`stop` `Command`s. Verified by `InputTests`.

The host (`mapview`) wires AppKit `NSEvent`s → tiles → the controller, draws the selection outline, and publishes the selected entity's live properties to the inspector panel. A reusable `CatalystInput` (the in-game host's event source) lands with the Catalyst app (Phase 6).

See `Documentation/Plan.v1.md` §4 (Phase 5).
