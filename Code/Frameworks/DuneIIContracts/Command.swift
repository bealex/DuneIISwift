/// A player/input order to the simulation — the `input → sim` seam. Presentation-free: a unit is
/// identified by its pool index and a target by a packed map tile, so neither input nor the sim needs
/// the other's types. The simulation translates a `Command` into the same unit order the original game
/// issues from a viewport click (`GUI_Widget_Viewport_Click`, `src/gui/viewport.c`).
public enum Command: Sendable, Equatable {
    /// Order the unit to move to `tile` (a packed map position).
    case move(unit: UInt16, tile: UInt16)
    /// Order the unit to attack whatever is at/around `tile`.
    case attack(unit: UInt16, tile: UInt16)
    /// Order the unit (a harvester) to harvest at `tile` — move there and gather spice.
    case harvest(unit: UInt16, tile: UInt16)
    /// Order the unit to retreat toward `tile`.
    case retreat(unit: UInt16, tile: UInt16)
    /// Order the unit to stop — hold position and guard (clear its move/attack targets).
    case stop(unit: UInt16)
    /// Issue a no-target action (`ActionType.rawValue`) to the unit — the original's `.unit`-selection action
    /// buttons (Guard / Retreat / Return / Deploy / Destruct / …): clear targets, then `Unit_SetAction`.
    case setAction(unit: UInt16, action: UInt8)
    /// Start the factory `structure` (a structure pool index) building `objectType` — a `UnitType.rawValue`
    /// for a unit factory, or a `StructureType.rawValue` for the construction yard (`Structure_BuildObject`).
    case build(structure: UInt16, objectType: UInt16)
    /// Order one `objectType` (`UnitType.rawValue`) from the starport `structure` — the CHOAM buy: charge the
    /// rolled `price`, chain the unit onto the house delivery list, decrement stock (`Structure_BuildObject`'s
    /// `FACTORY_BUY` body + the GUI credit charge). `price` is the `starportPrice` shown to the player.
    case starportOrder(structure: UInt16, objectType: UInt16, price: UInt16)
    /// Toggle the `structure`'s self-repair (`Structure_SetRepairingState`, −1 = toggle).
    case repair(structure: UInt16)
    /// Toggle the `structure`'s upgrade (`Structure_SetUpgradingState`, −1 = toggle).
    case upgrade(structure: UInt16)
    /// Cancel the factory `structure`'s in-progress build (`Structure_CancelBuild`; refunds the remainder).
    case cancelBuild(structure: UInt16)
    /// Pause the `structure`'s in-progress build — the player clicking the "%d%% DONE" item
    /// (`widget_click.c:124`, `STR_D_DONE`): sets `onHold` so the build stops advancing (and stops billing).
    case pauseBuild(structure: UInt16)
    /// Resume the `structure`'s held build/repair/upgrade — the player clicking the "ON HOLD" item
    /// (`widget_click.c:107`, `STR_ON_HOLD`): clears `repairing`/`onHold`/`upgrading` so the next tick
    /// continues (a build only progresses once credits are available again).
    case resumeBuild(structure: UInt16)
    /// Place the construction yard `structure`'s finished (ready) structure at `tile` (a packed map
    /// position), then reset the factory (`Structure_Place` + the GUI place-flow reset).
    case placeStructure(structure: UInt16, tile: UInt16)
    /// Fire the player palace `structure`'s house super-weapon now (`Structure_ActivateSpecial`). Used for
    /// the no-target weapons — Atreides Fremen call + Ordos saboteur. (Harkonnen's death-hand uses
    /// `launchHouseMissile`, which carries a target.)
    case activateSuperWeapon(structure: UInt16)
    /// Launch the player palace `structure`'s death-hand missile at `tile` (a packed map position) — the
    /// human's target-select click (`Structure_ActivateSpecial` → `Unit_LaunchHouseMissile`).
    case launchHouseMissile(structure: UInt16, tile: UInt16)
}
