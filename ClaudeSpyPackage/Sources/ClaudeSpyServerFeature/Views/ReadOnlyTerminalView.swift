#if os(macOS)
    import AppKit
    import SwiftTerm

    /// A container view that wraps a TerminalView and prevents it from receiving keyboard input.
    ///
    /// SwiftTerm's `TerminalView` on macOS doesn't expose `acceptsFirstResponder` or
    /// `becomeFirstResponder()` as `open`, so subclassing won't work. Instead, we wrap the
    /// terminal in a container that:
    /// 1. Forwards drawing and layout to the terminal view
    /// 2. Intercepts mouse clicks to prevent the terminal from becoming first responder
    /// 3. Lets the terminal handle its own scrolling via SwiftTerm's built-in scroll support
    ///
    /// Scroll preservation: Use `feedPreservingScroll` to preserve scroll position when
    /// the user has scrolled up from the bottom.
    final class ReadOnlyTerminalView: NSView {
        let terminalView: TerminalView

        /// Set to true to enable scroll preservation when feeding data
        var preserveUserScroll = false

        /// Callback for frame resize detection
        var onResize: ((NSSize) -> Void)?

        override init(frame: NSRect) {
            self.terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size))
            super.init(frame: frame)

            // Don't auto-resize - we manually control the terminal size to keep columns fixed
            terminalView.autoresizingMask = []
            addSubview(terminalView)
        }

        /// Sets the internal terminal view's frame size.
        /// Use this to control the terminal size independently of the container size.
        func setTerminalSize(_ size: NSSize) {
            terminalView.frame = NSRect(origin: .zero, size: size)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            onResize?(frame.size)
        }

        override var acceptsFirstResponder: Bool {
            false
        }

        /// Intercept mouse down to prevent the terminal from becoming first responder.
        /// We still allow the event to propagate for selection and scrolling purposes.
        override func mouseDown(with event: NSEvent) {
            // Don't call super or forward to terminalView - this prevents focus
            // Scrolling is handled by the parent NSScrollView
        }

        // MARK: - Forward TerminalView Properties

        var font: NSFont {
            get { terminalView.font }
            set { terminalView.font = newValue }
        }

        var nativeForegroundColor: NSColor {
            get { terminalView.nativeForegroundColor }
            set { terminalView.nativeForegroundColor = newValue }
        }

        var nativeBackgroundColor: NSColor {
            get { terminalView.nativeBackgroundColor }
            set { terminalView.nativeBackgroundColor = newValue }
        }

        func getTerminal() -> Terminal {
            terminalView.getTerminal()
        }

        func feed(byteArray: ArraySlice<UInt8>) {
            terminalView.feed(byteArray: byteArray)
        }

        /// Feeds data while preserving scroll position if user has scrolled up.
        /// Use this instead of `feed(byteArray:)` for streaming content.
        func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
            // Save current scroll position (0 = top, 1 = bottom)
            let savedPosition = scrollPosition
            let wasAtBottom = savedPosition >= 0.999

            // Feed the data (this will auto-scroll to bottom)
            terminalView.feed(byteArray: bytes)

            // If scroll preservation is enabled and user had scrolled up, restore position
            if preserveUserScroll && !wasAtBottom {
                terminalView.scroll(toPosition: savedPosition)
            }
        }

        func scroll(toPosition position: Double) {
            terminalView.scroll(toPosition: position)
        }

        var scrollPosition: Double {
            terminalView.scrollPosition
        }
    }
#endif
