#if os(macOS)
    import AppKit
    import SwiftTerm

    // MARK: - Scroll Event Overlay

    /// Intercepts events: horizontal scrolls handled here, vertical/mouse forwarded to terminal.
    final private class ScrollEventOverlay: NSView {
        weak var terminalView: TerminalView?
        var onHorizontalScroll: ((CGFloat) -> Void)?

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
            window?.makeFirstResponder(superview)
        }

        override func mouseDragged(with event: NSEvent) {
            terminalView?.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            terminalView?.mouseUp(with: event)
        }
    }

    // MARK: - ReadOnlyTerminalView

    /// Read-only terminal wrapper with horizontal scrolling. Prevents keyboard focus.
    final class ReadOnlyTerminalView: NSView {
        let terminalView: TerminalView
        private var horizontalScroller: NSScroller?
        private var scrollOverlay: ScrollEventOverlay?
        private var terminalWidth: CGFloat = 0
        private var horizontalOffset: CGFloat = 0

        var preserveUserScroll = false
        var onResize: ((NSSize) -> Void)?

        override init(frame: NSRect) {
            self.terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size))
            super.init(frame: frame)

            wantsLayer = true
            layer?.masksToBounds = true
            terminalView.autoresizingMask = []
            addSubview(terminalView)
            setupScrollOverlay()
            setupHorizontalScroller()
        }

        private func setupScrollOverlay() {
            let overlay = ScrollEventOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.terminalView = terminalView
            overlay.onHorizontalScroll = { [weak self] delta in
                self?.scrollHorizontally(by: delta)
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

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

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

        override var acceptsFirstResponder: Bool { false }

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
            // When there's no scrollback, position is ~0, and we should auto-scroll
            // when new content is added. The edge case of user scrolled to very top
            // is rare and acceptable to auto-scroll.
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
        /// This accounts for cell size and internal scroller width.
        func getOptimalFrameSize() -> NSRect {
            terminalView.getOptimalFrameSize()
        }
    }
#endif
