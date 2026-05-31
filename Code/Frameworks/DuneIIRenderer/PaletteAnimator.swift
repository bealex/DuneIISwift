import DuneIIFormats
import Foundation

/// Reproduces Dune II's palette cycling, ported from `GUI_PaletteAnimate` (OpenDUNE `gui/gui.c:643`)
/// and `GUI_Palette_ShiftColour` (`gui/gui.c:620`). Certain palette indices are animated over time by
/// shifting their RGB toward a reference color — pixels keep their index, only the index's color
/// changes. Driven at the 60 Hz GUI tick.
///
/// Animated indices (the raw `IBM.PAL` stores them as magenta placeholders meant to be overwritten):
/// - **223** — wind-trap / structure power light: pulses between palette entry 12 and 10, one step
///   per RGB component every 5 ticks.
/// - **255** — selection marker: pulses between entries 15 and 13, four steps every 3 ticks.
/// - **239** — repair/health flash: copies entry 15 or 6 every 60 ticks.
public enum PaletteAnimator {
    public static let windTrapIndex = 223
    public static let selectionIndex = 255
    public static let repairIndex = 239

    /// The per-tick cycle state the replay tracks (the targets it would otherwise recompute from
    /// scratch). Seed it at tick 0 and step forward with `stepTick` and you reproduce `animatedPalette`
    /// exactly, but at O(1) per tick instead of O(tick) per call — the form a per-frame renderer wants.
    public struct CycleState: Equatable, Sendable {
        var windTarget = 12
        var selectionTarget = 15
        var repairToggle = false
        public init() {}
    }

    /// Seed the animated indices to their cycle's initial reference colour, so they never show the raw
    /// `IBM.PAL` magenta placeholder before cycling has run. OpenDUNE runs `GUI_PaletteAnimate` during the
    /// load/fade before the map appears, so by the time the windtrap is visible index 223 has shifted
    /// toward colour 12 — a from-scratch renderer must seed it instead, or the windtrap light starts
    /// purple. 223 → entry 12 (windtrap `toggleColour`), 255 → entry 15 (selection), 239 → entry 15
    /// (repair) — the initial reference colours in `GUI_PaletteAnimate` (`gui/gui.c:643`).
    public static func seedAnimatedColours(_ colors: inout [Palette.Color]) {
        guard colors.count > selectionIndex else { return }
        colors[windTrapIndex] = colors[12]
        colors[selectionIndex] = colors[15]
        colors[repairIndex] = colors[15]
    }

    /// The palette as it appears `tick` GUI ticks (1/60 s each) after `base`. A pure function: it
    /// replays the cycling from tick 0, so callers can drive it straight from elapsed time. **O(tick)** —
    /// fine for a one-off lookup (a single asset preview), but a per-frame world renderer should instead
    /// keep a `CycleState` + colours and advance with `stepTick` (O(1) per tick), or it slows linearly as
    /// the game runs.
    public static func animatedPalette(base: Palette, tick: Int) -> Palette {
        guard tick > 0 else { return base }
        var colors = base.colors
        guard colors.count > selectionIndex else { return base }
        var state = CycleState()
        for step in 1 ... tick { _ = stepTick(&colors, tick: step, state: &state) }
        return Palette(colors: colors)
    }

    /// Advance `colors` by exactly the cycling of GUI tick `tick` (one iteration of `animatedPalette`'s
    /// loop), updating `state`. Returns whether any animated index's colour changed — a renderer can skip
    /// recolouring when nothing moved. Stepping `1...T` from `base` + a fresh `CycleState` equals
    /// `animatedPalette(base:tick:T)`.
    @discardableResult
    public static func stepTick(_ colors: inout [Palette.Color], tick: Int, state: inout CycleState) -> Bool {
        guard tick > 0, colors.count > selectionIndex else { return false }
        var changed = false

        if tick % 5 == 0 {
            let before = colors[windTrapIndex]
            if !shift(&colors, windTrapIndex, toward: state.windTarget) {
                state.windTarget = state.windTarget == 12 ? 10 : 12
            }
            changed = changed || colors[windTrapIndex] != before
        }
        if tick % 3 == 0 {
            let before = colors[selectionIndex]
            for _ in 0 ..< 4 { _ = shift(&colors, selectionIndex, toward: state.selectionTarget) }
            if equal(colors, selectionIndex, state.selectionTarget) {
                state.selectionTarget = state.selectionTarget == 15 ? 13 : 15
            }
            changed = changed || colors[selectionIndex] != before
        }
        if tick % 60 == 0 {
            let before = colors[repairIndex]
            colors[repairIndex] = state.repairToggle ? colors[6] : colors[15]
            state.repairToggle.toggle()
            changed = changed || colors[repairIndex] != before
        }
        return changed
    }

    /// Move each RGB component of `colors[index]` one step toward `colors[reference]`. Returns whether
    /// any component still differed (i.e. the color was still moving).
    private static func shift(_ colors: inout [Palette.Color], _ index: Int, toward reference: Int) -> Bool {
        let target = colors[reference]
        let before = colors[index]
        colors[index].red = step(before.red, toward: target.red)
        colors[index].green = step(before.green, toward: target.green)
        colors[index].blue = step(before.blue, toward: target.blue)
        return colors[index] != before
    }

    private static func step(_ value: UInt8, toward target: UInt8) -> UInt8 {
        if value > target { return value - 1 }
        if value < target { return value + 1 }
        return value
    }

    private static func equal(_ colors: [Palette.Color], _ index: Int, _ reference: Int) -> Bool {
        colors[index] == colors[reference]
    }
}
