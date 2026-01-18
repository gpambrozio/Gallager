#if os(iOS)
    import SwiftTerm
    import UIKit

    /// A read-only terminal view that disables keyboard input while preserving scrolling.
    ///
    /// SwiftTerm's `TerminalView` extends `UIScrollView`, so scrolling works automatically.
    /// By returning `false` from `canBecomeFirstResponder`, we prevent the keyboard from
    /// appearing and block all keyboard input.
    final class ReadOnlyTerminalView: TerminalView {
        override var canBecomeFirstResponder: Bool {
            false
        }
    }
#endif
