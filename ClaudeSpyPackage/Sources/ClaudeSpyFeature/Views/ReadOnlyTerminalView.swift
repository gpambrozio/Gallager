#if os(iOS)
    import SwiftTerm
    import UIKit

    /// A read-only terminal view that disables keyboard input while preserving scrolling.
    ///
    /// SwiftTerm's `TerminalView` extends `UIScrollView`, so scrolling works automatically.
    /// By returning `false` from `canBecomeFirstResponder`, we prevent the keyboard from
    /// appearing and block all keyboard input.
    ///
    /// Scroll preservation: After initial content is loaded, if the user has scrolled up,
    /// their scroll position is preserved when new content arrives. Use `feedPreservingScroll`
    /// instead of `feed` to enable this behavior.
    final class ReadOnlyTerminalView: TerminalView {
        /// Set to true after initial content has been loaded to enable scroll preservation
        var preserveUserScroll = false

        /// When true, blocks all contentOffset changes to preserve scroll position
        private var blockScrollChanges = false

        override var canBecomeFirstResponder: Bool {
            false
        }

        /// Block contentOffset changes while preserving scroll position
        override var contentOffset: CGPoint {
            get { super.contentOffset }
            set {
                if blockScrollChanges {
                    return // Ignore all scroll changes
                }
                super.contentOffset = newValue
            }
        }

        /// Feeds data while preserving scroll position if user has scrolled up.
        /// Use this instead of `feed(byteArray:)` for streaming content.
        func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
            if preserveUserScroll {
                // Check if at bottom before feeding
                let maxScrollY = max(0, contentSize.height - bounds.height)
                let isAtBottom = maxScrollY <= 0 || super.contentOffset.y >= maxScrollY - 5
                blockScrollChanges = !isAtBottom
            }

            feed(byteArray: bytes)

            blockScrollChanges = false
        }
    }
#endif
