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

    /// The palette as it appears `tick` GUI ticks (1/60 s each) after `base`. A pure function: it
    /// replays the cycling from tick 0, so callers can drive it straight from elapsed time. Each tick
    /// is O(1) (only three indices move), so replaying a few thousand ticks per frame is cheap.
    public static func animatedPalette(base: Palette, tick: Int) -> Palette {
        guard tick > 0 else { return base }

        var colors = base.colors
        guard colors.count > selectionIndex else { return base }

        var windTarget = 12
        var selectionTarget = 15
        var repairToggle = false

        for step in 1 ... tick {
            if step % 5 == 0 {
                if !shift(&colors, windTrapIndex, toward: windTarget) {
                    windTarget = windTarget == 12 ? 10 : 12
                }
            }
            if step % 3 == 0 {
                for _ in 0 ..< 4 { _ = shift(&colors, selectionIndex, toward: selectionTarget) }
                if equal(colors, selectionIndex, selectionTarget) {
                    selectionTarget = selectionTarget == 15 ? 13 : 15
                }
            }
            if step % 60 == 0 {
                colors[repairIndex] = repairToggle ? colors[6] : colors[15]
                repairToggle.toggle()
            }
        }
        return Palette(colors: colors)
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
