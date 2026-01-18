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
    final class ReadOnlyTerminalView: NSView {
        let terminalView: TerminalView

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

        func scroll(toPosition position: Double) {
            terminalView.scroll(toPosition: position)
        }
    }
#endif
