import SwiftUI

extension View {
    /// Size a popover's content so it fits on small landscape screens.
    ///
    /// We play landscape-only, so popovers can be **wider** than the cramped portrait defaults; but a small
    /// iPhone in landscape is only ~390–430 pt tall, which the original fixed-height popovers overflowed (the
    /// content was clipped, with no way to scroll to the rest). So instead of a hard `height:` we set `width`
    /// plus a `maxHeight`: the frame shrinks to whatever the screen offers, and the content's own scrolling
    /// container (a `List`, `Form`, or `ScrollView`) scrolls the overflow.
    ///
    /// On iOS we also pin the presentation to an anchored popover (`.presentationCompactAdaptation(.popover)`)
    /// — otherwise a compact size class adapts it into a bottom sheet that ignores our `width`.
    func gamePopover(width: CGFloat, maxHeight: CGFloat) -> some View {
        #if os(iOS)
            // Small landscape screens: shrink to fit, let the content's own List/Form/ScrollView scroll.
            return frame(width: width).frame(maxHeight: maxHeight).presentationCompactAdaptation(.popover)
        #else
            // macOS has room: give the popover a **definite** height. A bare `maxHeight` lets a `List` (no
            // intrinsic height) collapse to a couple of rows — the "too small vertically" bug — so the popover
            // must propose a concrete height for the content to fill.
            return frame(width: width, height: maxHeight)
        #endif
    }
}
