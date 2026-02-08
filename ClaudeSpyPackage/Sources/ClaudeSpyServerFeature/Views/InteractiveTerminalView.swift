#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
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
        weak var interactiveView: InteractiveTerminalView?
        var onHorizontalScroll: ((CGFloat) -> Void)?
        var onMouseDown: (() -> Void)?
        var onMouseMoved: ((NSEvent) -> Void)?
        var onMouseExited: (() -> Void)?
        var onFlagsChanged: ((NSEvent) -> Void)?

        private var trackingArea: NSTrackingArea?

        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            onMouseMoved?(event)
        }

        override func mouseExited(with event: NSEvent) {
            onMouseExited?()
        }

        override func flagsChanged(with event: NSEvent) {
            onFlagsChanged?(event)
            super.flagsChanged(with: event)
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
            // If Cmd is held, check for plain-text URL before forwarding to SwiftTerm.
            // SwiftTerm handles OSC 8 links in its own mouseUp; this handles plain-text URLs.
            if event.modifierFlags.contains(.command),
               let interactive = interactiveView
            {
                let point = interactive.convert(event.locationInWindow, from: nil)
                if interactive.handleCommandClick(at: point) {
                    return
                }
            }
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
    /// - Detects plain-text URLs: Cmd+hover highlights, Cmd+click opens in browser
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

        // URL detection state
        private var commandKeyActive = false
        private var urlCursorPushed = false
        private var urlPreviewField: NSTextField?
        private var highlightedURLRange: (row: Int, startCol: Int, endCol: Int)?
        private var urlHighlightLayer: CALayer?

        private var isFocused = false {
            didSet {
                focusBorderView?.isFocused = isFocused
            }
        }

        // Using nonisolated(unsafe) for notification observer cleanup in deinit
        private nonisolated(unsafe) var windowObserver: (any NSObjectProtocol)?

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

        deinit {
            if let observer = windowObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        // MARK: - Setup

        private func setupScrollOverlay() {
            let overlay = ScrollEventOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.terminalView = terminalView
            overlay.interactiveView = self
            overlay.onHorizontalScroll = { [weak self] delta in
                self?.scrollHorizontally(by: delta)
            }
            overlay.onMouseDown = { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
            overlay.onMouseMoved = { [weak self] event in
                self?.handleMouseMoved(event)
            }
            overlay.onMouseExited = { [weak self] in
                self?.handleMouseExited()
            }
            overlay.onFlagsChanged = { [weak self] event in
                self?.handleFlagsChanged(event)
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

            // Clean up old observer
            if let observer = windowObserver {
                NotificationCenter.default.removeObserver(observer)
                windowObserver = nil
            }

            guard let window else { return }

            // Auto-focus when added to a window
            Task { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }

            // Re-focus when window becomes key (e.g., after switching apps)
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let window = self.window else { return }
                    window.makeFirstResponder(self)
                }
            }
        }

        // MARK: - Keyboard Events

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command) else {
                return false
            }

            switch event.charactersIgnoringModifiers {
            case "v":
                // Handle Cmd+V paste
                let pasteboard = NSPasteboard.general

                // If clipboard has text, send it directly to tmux
                if let clipboardString = pasteboard.string(forType: .string), !clipboardString.isEmpty {
                    onInput?([.text(clipboardString)])
                    return true
                }

                // If clipboard has an image, send Ctrl+V so the terminal app can handle it
                if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
                    onInput?([.ctrl("v")])
                    return true
                }

                return false

            case "c":
                // Copy selected text to clipboard
                if let selectedText = terminalView.getSelection() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedText, forType: .string)
                    return true
                }
                return false

            default:
                return false
            }
        }

        override func keyDown(with event: NSEvent) {
            // Let the terminal view interpret the key
            terminalView.keyDown(with: event)
        }

        // MARK: - URL Detection

        /// Converts a point in this view's coordinate space to a viewport grid position (col, row).
        /// The returned row is a viewport row suitable for `Terminal.getLine(row:)`.
        private func gridPosition(for point: NSPoint) -> (col: Int, row: Int)? {
            let cellSize = FontMetrics.calculateCellSize(font: terminalView.font as CTFont)
            guard cellSize.width > 0, cellSize.height > 0 else { return nil }

            // Convert point to terminal view coordinates (accounting for horizontal scroll offset)
            let terminalPoint = NSPoint(
                x: point.x + horizontalOffset,
                y: point.y
            )

            let terminal = terminalView.getTerminal()

            // SwiftTerm uses flipped coordinates (origin at top-left for content)
            let col = Int(terminalPoint.x / cellSize.width)
            let row = Int((terminalView.frame.height - terminalPoint.y) / cellSize.height)

            let clampedCol = min(max(0, col), terminal.cols - 1)
            let clampedRow = min(max(0, row), terminal.rows - 1)

            return (clampedCol, clampedRow)
        }

        private func handleFlagsChanged(_ event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                commandKeyActive = true
                // Check if mouse is currently over a URL
                let localPoint = convert(event.locationInWindow, from: nil)
                updateURLHighlight(at: localPoint)
            } else {
                commandKeyActive = false
                resetURLCursor()
                removeURLHighlight()
                removeURLPreview()
            }
        }

        private func handleMouseMoved(_ event: NSEvent) {
            guard commandKeyActive else { return }
            let point = convert(event.locationInWindow, from: nil)
            updateURLHighlight(at: point)
        }

        private func handleMouseExited() {
            resetURLCursor()
            removeURLHighlight()
            removeURLPreview()
        }

        private func updateURLHighlight(at point: NSPoint) {
            guard let pos = gridPosition(for: point) else {
                resetURLCursor()
                removeURLHighlight()
                removeURLPreview()
                return
            }

            let terminal = terminalView.getTerminal()
            let urls = TerminalURLDetector.detectURLs(row: pos.row) {
                terminal.getLine(row: $0)?.translateToString(trimRight: true)
            }
            if let detected = urls.first(where: { pos.col >= $0.startCol && pos.col < $0.endCol }) {
                let newRange = (row: pos.row, startCol: detected.startCol, endCol: detected.endCol)
                if highlightedURLRange?.row == newRange.row,
                   highlightedURLRange?.startCol == newRange.startCol,
                   highlightedURLRange?.endCol == newRange.endCol
                {
                    return // Already highlighting this URL
                }
                highlightedURLRange = newRange
                showURLHighlight(row: pos.row, startCol: detected.startCol, endCol: detected.endCol)
                showURLPreview(detected.url)
                if !urlCursorPushed {
                    NSCursor.pointingHand.push()
                    urlCursorPushed = true
                }
            } else {
                resetURLCursor()
                removeURLHighlight()
                removeURLPreview()
            }
        }

        private func showURLHighlight(row: Int, startCol: Int, endCol: Int) {
            let cellSize = FontMetrics.calculateCellSize(font: terminalView.font as CTFont)

            // row is a viewport row. Calculate rect in terminal view coordinates
            // (NSView: origin at bottom-left, but terminal rows count from top)
            let x = CGFloat(startCol) * cellSize.width - horizontalOffset
            let y = terminalView.frame.height - CGFloat(row + 1) * cellSize.height
            let width = CGFloat(endCol - startCol) * cellSize.width

            let highlightRect = CGRect(x: x, y: y, width: width, height: cellSize.height)

            if urlHighlightLayer == nil {
                let layer = CALayer()
                layer.backgroundColor = NSColor.linkColor.withAlphaComponent(0.15).cgColor
                layer.borderColor = NSColor.linkColor.withAlphaComponent(0.3).cgColor
                layer.borderWidth = 1
                layer.cornerRadius = 2
                terminalView.layer?.addSublayer(layer)
                urlHighlightLayer = layer
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            urlHighlightLayer?.frame = highlightRect
            CATransaction.commit()
        }

        private func removeURLHighlight() {
            urlHighlightLayer?.removeFromSuperlayer()
            urlHighlightLayer = nil
            highlightedURLRange = nil
        }

        private func showURLPreview(_ url: String) {
            if let preview = urlPreviewField {
                preview.stringValue = url
                preview.sizeToFit()
                preview.frame.size.width = min(preview.frame.size.width, bounds.width - 8)
            } else {
                let field = NSTextField(string: url)
                field.isBezeled = false
                field.isEditable = false
                field.isSelectable = false
                field.lineBreakMode = .byTruncatingMiddle
                field.font = NSFont.systemFont(ofSize: 11)
                field.backgroundColor = NSColor.windowBackgroundColor
                field.textColor = NSColor.labelColor
                field.sizeToFit()
                field.frame.origin = CGPoint(x: 4, y: 4)
                field.frame.size.width = min(field.frame.size.width, bounds.width - 8)
                addSubview(field)
                urlPreviewField = field
            }
        }

        private func removeURLPreview() {
            urlPreviewField?.removeFromSuperview()
            urlPreviewField = nil
        }

        private func resetURLCursor() {
            if urlCursorPushed {
                NSCursor.pop()
                urlCursorPushed = false
            }
        }

        /// Called by the scroll overlay when Cmd+click happens - check for plain-text URL.
        fileprivate func handleCommandClick(at point: NSPoint) -> Bool {
            guard let pos = gridPosition(for: point) else { return false }
            let terminal = terminalView.getTerminal()
            let lineText: (Int) -> String? = { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            if let url = TerminalURLDetector.urlAt(col: pos.col, row: pos.row, lineText: lineText),
               let nsURL = URL(string: url)
            {
                NSWorkspace.shared.open(nsURL)
                return true
            }
            return false
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
