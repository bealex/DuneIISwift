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
        let sized = frame(width: width).frame(maxHeight: maxHeight)
        #if os(iOS)
            return sized.presentationCompactAdaptation(.popover)
        #else
            return sized
        #endif
    }
}
