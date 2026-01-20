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
    /// 3. Still allows scroll events to pass through to the parent NSScrollView
    ///
    /// Scroll preservation: Use `feedPreservingScroll` to preserve scroll position when
    /// the user has scrolled up from the bottom.
    final class ReadOnlyTerminalView: NSView {
        let terminalView: TerminalView

        /// Set to true to enable scroll preservation when feeding data
        var preserveUserScroll = false

        override init(frame: NSRect) {
            self.terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size))
            super.init(frame: frame)

            terminalView.autoresizingMask = [.width, .height]
            addSubview(terminalView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
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

        /// Forward scroll events to parent NSScrollView for panning.
        ///
        /// SwiftTerm's TerminalView intercepts all scroll events for terminal scrollback,
        /// ignoring deltaX completely and never passing events to parent views.
        /// We need to forward events to enable:
        /// 1. Horizontal panning (deltaX) - always forwarded to parent
        /// 2. Vertical panning (deltaY) - forwarded to parent when needed
        override func scrollWheel(with event: NSEvent) {
            // Find the enclosing scroll view
            guard let scrollView = enclosingScrollView else {
                // No scroll view, let terminal handle it
                terminalView.scrollWheel(with: event)
                return
            }

            // Always forward horizontal scroll to parent for panning
            if event.deltaX != 0 {
                scrollView.scrollWheel(with: event)
                return
            }

            // For vertical scroll, check if we need panning or terminal scrollback
            let clipView = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let visibleHeight = clipView.bounds.height

            // If terminal view fits entirely in the scroll view, use terminal scrollback
            if documentHeight <= visibleHeight {
                terminalView.scrollWheel(with: event)
                return
            }

            // Terminal is larger than view - need to handle both panning and scrollback
            // For now, prioritize panning via parent scroll view
            // Users can use terminal's built-in scrollback via keyboard or scrollbar
            scrollView.scrollWheel(with: event)
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
