#if os(macOS)
    import AppKit
    import ClaudeSpyNetworking
    import SwiftTerm

    // MARK: - Focus Border Overlay

    /// Provides a subtle border highlight when the terminal has keyboard focus.
    final private class FocusBorderView: NSView {
        var isFocused = false {
            didSet {
                guard isFocused != oldValue else { return }
                needsDisplay = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isFocused else { return }

            let borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
            borderColor.setStroke()

            let borderPath = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            borderPath.lineWidth = 2
            borderPath.stroke()
        }
    }

    // MARK: - Scroll Event Overlay

    /// Intercepts events: horizontal scrolls handled here, vertical/mouse forwarded to terminal.
    final private class ScrollEventOverlay: NSView {
        weak var terminalView: TerminalView?
        var onHorizontalScroll: ((CGFloat) -> Void)?
        var onMouseDown: (() -> Void)?

        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                onHorizontalScroll?(-event.scrollingDeltaX)
            } else {
                terminalView?.scrollWheel(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            terminalView?.mouseDown(with: event)
            onMouseDown?()
        }

        override func mouseDragged(with event: NSEvent) {
            terminalView?.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            terminalView?.mouseUp(with: event)
        }
    }

    // MARK: - Interactive Terminal View

    /// Terminal wrapper that accepts keyboard input and forwards keystrokes via callback.
    ///
    /// Features:
    /// - Accepts first responder for keyboard input
    /// - Implements `TerminalViewDelegate` to capture typed characters
    /// - Converts raw bytes to `TmuxKey` representations for relay transmission
    /// - Preserves scroll position when new content arrives
    /// - Shows subtle border highlight when focused
    /// - Supports horizontal scrolling for wide terminals
    final class InteractiveTerminalView: NSView {
        let terminalView: TerminalView
        private var horizontalScroller: NSScroller?
        private var scrollOverlay: ScrollEventOverlay?
        private var focusBorderView: FocusBorderView?
        private var terminalWidth: CGFloat = 0
        private var horizontalOffset: CGFloat = 0

        /// Callback invoked when the user types. The keys are ready for relay transmission.
        var onInput: (@MainActor ([TmuxKey]) -> Void)?

        var preserveUserScroll = false
        var onResize: ((NSSize) -> Void)?

        private var isFocused = false {
            didSet {
                focusBorderView?.isFocused = isFocused
            }
        }

        override init(frame: NSRect) {
            self.terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size))
            super.init(frame: frame)

            wantsLayer = true
            layer?.masksToBounds = true
            terminalView.autoresizingMask = []
            terminalView.terminalDelegate = self
            addSubview(terminalView)
            setupScrollOverlay()
            setupHorizontalScroller()
            setupFocusBorder()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: - Setup

        private func setupScrollOverlay() {
            let overlay = ScrollEventOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.terminalView = terminalView
            overlay.onHorizontalScroll = { [weak self] delta in
                self?.scrollHorizontally(by: delta)
            }
            overlay.onMouseDown = { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
            addSubview(overlay)
            scrollOverlay = overlay
        }

        private func setupHorizontalScroller() {
            let scrollerHeight = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
            let scrollerFrame = NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: scrollerHeight
            )

            let scroller = NSScroller(frame: scrollerFrame)
            scroller.scrollerStyle = .overlay
            scroller.knobProportion = 1
            scroller.isEnabled = false
            scroller.alphaValue = 0
            scroller.autoresizingMask = [.width]
            scroller.target = self
            scroller.action = #selector(horizontalScrollerActivated)
            addSubview(scroller)

            horizontalScroller = scroller
        }

        private func setupFocusBorder() {
            let borderView = FocusBorderView(frame: bounds)
            borderView.autoresizingMask = [.width, .height]
            addSubview(borderView)
            focusBorderView = borderView
        }

        // MARK: - First Responder

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            isFocused = true
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            isFocused = false
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Auto-focus when added to a window
            if window != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.window?.makeFirstResponder(self)
                }
            }
        }

        // MARK: - Keyboard Events

        override func keyDown(with event: NSEvent) {
            // Let the terminal view interpret the key
            terminalView.keyDown(with: event)
        }

        // MARK: - Horizontal Scrolling

        @objc
        private func horizontalScrollerActivated() {
            guard let scroller = horizontalScroller else { return }
            let maxOffset = terminalWidth - bounds.width

            switch scroller.hitPart {
            case .knob,
                 .knobSlot where maxOffset > 0:
                horizontalOffset = scroller.doubleValue * maxOffset
                updateTerminalPosition()
            case .decrementPage:
                scrollHorizontally(by: -bounds.width * 0.9)
            case .incrementPage:
                scrollHorizontally(by: bounds.width * 0.9)
            default:
                break
            }
        }

        private func scrollHorizontally(by delta: CGFloat) {
            let maxOffset = terminalWidth - bounds.width
            guard maxOffset > 0 else { return }

            horizontalOffset = max(0, min(maxOffset, horizontalOffset + delta))
            updateTerminalPosition()
            updateHorizontalScroller()
        }

        private func updateTerminalPosition() {
            var frame = terminalView.frame
            frame.origin.x = -horizontalOffset
            terminalView.frame = frame
        }

        private func updateHorizontalScroller() {
            guard let scroller = horizontalScroller else { return }
            let maxOffset = terminalWidth - bounds.width
            let needsScroll = maxOffset > 0

            scroller.isEnabled = needsScroll
            scroller.alphaValue = needsScroll ? 1 : 0
            scroller.knobProportion = needsScroll ? bounds.width / terminalWidth : 1
            if needsScroll {
                scroller.doubleValue = horizontalOffset / maxOffset
            }
        }

        func setTerminalSize(_ size: NSSize) {
            terminalWidth = size.width
            terminalView.frame = NSRect(x: -horizontalOffset, y: 0, width: size.width, height: bounds.height)

            let maxOffset = max(0, terminalWidth - bounds.width)
            if horizontalOffset > maxOffset {
                horizontalOffset = maxOffset
                updateTerminalPosition()
            }
            updateHorizontalScroller()
        }

        // MARK: - Layout

        override func layout() {
            super.layout()
            if let scroller = horizontalScroller {
                let h = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
                scroller.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
            }
            terminalView.frame.size.height = bounds.height
            updateHorizontalScroller()
            onResize?(frame.size)
        }

        // MARK: - TerminalView Forwarding

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
            set {
                terminalView.nativeBackgroundColor = newValue
                layer?.backgroundColor = newValue.cgColor
            }
        }

        func getTerminal() -> Terminal {
            terminalView.getTerminal()
        }

        func feed(byteArray: ArraySlice<UInt8>) {
            terminalView.feed(byteArray: byteArray)
        }

        func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
            let savedPosition = scrollPosition
            // Consider "at bottom" if:
            // - Position >= 0.999 (actually at bottom)
            // - Position <= 0.001 (no scrollback yet, or at very top)
            let wasAtExtreme = savedPosition >= 0.999 || savedPosition <= 0.001
            terminalView.feed(byteArray: bytes)
            if preserveUserScroll, !wasAtExtreme {
                terminalView.scroll(toPosition: savedPosition)
            }
        }

        func scroll(toPosition position: Double) {
            terminalView.scroll(toPosition: position)
        }

        var scrollPosition: Double {
            terminalView.scrollPosition
        }

        /// Returns the optimal frame size for the current terminal dimensions.
        func getOptimalFrameSize() -> NSRect {
            terminalView.getOptimalFrameSize()
        }
    }

    // MARK: - TerminalViewDelegate

    extension InteractiveTerminalView: @preconcurrency TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Convert raw bytes to TmuxKey representations
            let keys = TmuxKey.from(bytes: Data(data))
            guard !keys.isEmpty else { return }
            onInput?(keys)
        }

        func scrolled(source: TerminalView, position: Double) {
            // No-op - scrolling is handled by the view
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // No-op - we don't track titles in this context
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // No-op - size is managed externally
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // No-op
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let string = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // No-op
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // No-op - iTerm2 specific sequences not needed
        }
    }
#endif
