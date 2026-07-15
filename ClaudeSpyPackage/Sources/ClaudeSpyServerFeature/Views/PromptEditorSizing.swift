import CoreGraphics

/// Pure sizing math for `PromptEditorOverlay` (issue #656).
///
/// The overlay defaults to 80% × 50% of its parent pane, pinned to the top and
/// horizontally centered. The user can drag its bottom/trailing edges to any
/// size between half the default and the full parent, and while typing the
/// overlay grows its height so new lines stay visible until it reaches the
/// parent's height — beyond that the text scrolls as before.
enum PromptEditorSizing {
    static let defaultWidthFraction: CGFloat = 0.8
    static let defaultHeightFraction: CGFloat = 0.5
    /// The user can shrink the overlay to half its default size…
    static let minWidthFraction: CGFloat = defaultWidthFraction / 2
    static let minHeightFraction: CGFloat = defaultHeightFraction / 2
    /// …and grow it to fill the whole parent view.
    static let maxFraction: CGFloat = 1

    static func clampedWidthFraction(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, minWidthFraction), maxFraction)
    }

    static func clampedHeightFraction(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, minHeightFraction), maxFraction)
    }

    /// Width fraction after dragging a trailing resize handle horizontally.
    ///
    /// The card stays horizontally centered, so its trailing edge moves half as
    /// fast as its width grows — the pointer delta is doubled to keep the
    /// handle under the cursor.
    static func widthFraction(
        afterDragging translation: CGFloat,
        fromWidth startWidth: CGFloat,
        parentWidth: CGFloat
    ) -> CGFloat {
        guard parentWidth > 0 else { return defaultWidthFraction }
        return clampedWidthFraction((startWidth + translation * 2) / parentWidth)
    }

    /// Height fraction after dragging a bottom resize handle vertically. The
    /// card is pinned to the top, so its bottom edge tracks the pointer 1:1.
    static func heightFraction(
        afterDragging translation: CGFloat,
        fromHeight startHeight: CGFloat,
        parentHeight: CGFloat
    ) -> CGFloat {
        guard parentHeight > 0 else { return defaultHeightFraction }
        return clampedHeightFraction((startHeight + translation) / parentHeight)
    }

    /// Grow-only height while typing: returns a taller fraction when the
    /// content needs more room than the current height, capped at the full
    /// parent. Never shrinks — deleting text or a manual resize below the
    /// content height is respected and the text scrolls instead.
    static func heightFraction(
        growing current: CGFloat,
        toFitRequiredHeight requiredHeight: CGFloat,
        parentHeight: CGFloat
    ) -> CGFloat {
        guard parentHeight > 0 else { return current }
        let required = requiredHeight / parentHeight
        guard required > current else { return current }
        return min(required, maxFraction)
    }
}
