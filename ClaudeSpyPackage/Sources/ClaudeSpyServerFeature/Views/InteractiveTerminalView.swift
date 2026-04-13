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
        var onCursorUpdate: ((NSEvent) -> Void)?

        private var trackingArea: NSTrackingArea?

        /// Accumulated scroll delta for smooth mouse-wheel event generation.
        /// Trackpad events deliver fractional deltas; we accumulate them and
        /// emit one scroll event per line crossed.
        private var scrollAccumulator: CGFloat = 0

        /// Tracks whether the current mouse gesture (mouseDown → drag → mouseUp)
        /// is forcing local text selection by temporarily disabling SwiftTerm's
        /// mouse reporting. Set on Shift+mouseDown when mouse mode is active,
        /// cleared on mouseUp. This follows the standard terminal emulator
        /// convention (iTerm2, Terminal.app, xterm) where Shift bypasses mouse
        /// reporting so the user can select text even when the app owns the mouse.
        private var forceLocalSelection = false

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
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            // Don't forward motion events when mouse mode is active. SwiftTerm
            // generates motion escape sequences (ESC[<32;col;rowm) that some
            // apps misinterpret as button release events, triggering click actions.
            // Terminal apps primarily need clicks and scrolls, not hover tracking.
            if interactiveView?.isMouseModeActive != true {
                onMouseMoved?(event)
            }
        }

        override func mouseExited(with event: NSEvent) {
            onMouseExited?()
        }

        override func cursorUpdate(with event: NSEvent) {
            onCursorUpdate?(event)
        }

        override func scrollWheel(with event: NSEvent) {
            // When mouse mode is active, synthesize SGR mouse wheel escape sequences
            // and batch them into a single onRawInput call. This is critical because
            // each onRawInput spawns one tmux subprocess — batching N scroll lines
            // into one call avoids N separate process forks.
            //
            // Shift+scroll bypasses mouse reporting and scrolls the local terminal
            // scrollback, matching the standard terminal emulator convention.
            if
                let interactive = interactiveView,
                interactive.isMouseModeActive,
                !event.modifierFlags.contains(.shift),
                let tv = terminalView {
                let deltaY = event.scrollingDeltaY
                guard deltaY != 0 else { return }

                // Reset accumulator on direction change for responsive reversal.
                if (scrollAccumulator > 0) != (deltaY > 0) {
                    scrollAccumulator = 0
                }

                scrollAccumulator += deltaY

                let point = tv.convert(event.locationInWindow, from: nil)
                let terminal = tv.getTerminal()
                let col = min(max(0, Int(point.x / interactive.cellSize.width)), terminal.cols - 1)
                let row = min(max(0, Int((tv.frame.height - point.y) / interactive.cellSize.height)), terminal.rows - 1)

                // Build batched SGR mouse scroll sequences. Each line crossed
                // produces one ESC[<button;col;rowM sequence. They're concatenated
                // into a single Data and sent as one tmux send-keys -H call.
                //
                // NSEvent.scrollingDeltaY semantics depend on the device:
                // - Mouse wheel (hasPreciseScrollingDeltas == false): delta is
                //   already in *lines*, so the threshold is 1.
                // - Trackpad (hasPreciseScrollingDeltas == true): delta is in
                //   *points* (pixels). We divide by the terminal cell height so
                //   one cell-row of pixel scroll becomes one line event — the
                //   scroll rate then matches what the user sees visually. Without
                //   this, a modest swipe of ~40pt would emit ~40 line events and
                //   the terminal would leap dozens of lines at once.
                let lineThreshold: CGFloat = event.hasPreciseScrollingDeltas
                    ? max(interactive.cellSize.height, 1)
                    : 1
                var lines = 0
                while abs(scrollAccumulator) >= lineThreshold {
                    lines += 1
                    scrollAccumulator -= scrollAccumulator > 0 ? lineThreshold : -lineThreshold
                }
                guard lines > 0 else { return }

                // Button 64 = scroll up, 65 = scroll down (SGR encoding)
                let button = deltaY > 0 ? 64 : 65
                // SGR format: ESC [ < Cb ; Cx ; Cy M  (1-indexed coordinates)
                let singleEvent = "\u{1b}[<\(button);\(col + 1);\(row + 1)M"
                let batch = String(repeating: singleEvent, count: lines)
                interactive.onRawInput?(Data(batch.utf8))
                return
            }
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                onHorizontalScroll?(-event.scrollingDeltaX)
            } else {
                terminalView?.scrollWheel(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            // Reset any stale state from an interrupted prior gesture.
            if forceLocalSelection {
                terminalView?.allowMouseReporting = true
                forceLocalSelection = false
            }
            // Shift+click bypasses mouse reporting so the user can select text
            // even when the terminal app has mouse mode enabled.
            if
                event.modifierFlags.contains(.shift),
                interactiveView?.isMouseModeActive == true {
                forceLocalSelection = true
                terminalView?.allowMouseReporting = false
            }
            terminalView?.mouseDown(with: event)
            onMouseDown?()
        }

        override func mouseDragged(with event: NSEvent) {
            // When mouse mode is active, synthesize SGR drag (motion) escape
            // sequences ourselves. SwiftTerm only emits motion events for
            // .anyEvent mode (1003), silently dropping them for
            // .buttonEventTracking (1002). Bypassing SwiftTerm and sending
            // directly via onRawInput also avoids the motion-event filter in
            // send(source:data:) which suppresses SwiftTerm-internal tracking.
            if
                !forceLocalSelection,
                let interactive = interactiveView,
                interactive.isMouseModeActive,
                let tv = terminalView {
                let point = tv.convert(event.locationInWindow, from: nil)
                let terminal = tv.getTerminal()
                let col = min(
                    max(0, Int(point.x / interactive.cellSize.width)),
                    terminal.cols - 1
                )
                let row = min(
                    max(0, Int((tv.frame.height - point.y) / interactive.cellSize.height)),
                    terminal.rows - 1
                )
                // SGR drag: button 32 (left button + motion bit 5)
                // Format: ESC [ < 32 ; col ; row M  (1-indexed coordinates)
                let seq = "\u{1b}[<32;\(col + 1);\(row + 1)M"
                interactive.onRawInput?(Data(seq.utf8))
                return
            }
            terminalView?.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            // End of a Shift+drag local selection gesture — restore mouse reporting
            // and handle auto-copy the same way as when mouse mode is off.
            if forceLocalSelection {
                // Call mouseUp before restoring reporting so SwiftTerm finalises
                // selection without emitting an SGR release escape to the terminal app.
                terminalView?.mouseUp(with: event)
                terminalView?.allowMouseReporting = true
                forceLocalSelection = false

                if
                    let interactive = interactiveView,
                    interactive.autoCopyOnSelect,
                    interactive.getSelectedTextTrimmed() != nil {
                    interactive.copySelectionToClipboard()
                }
                return
            }

            // When mouse mode is active, skip URL detection and auto-copy —
            // the terminal app owns mouse interaction.
            if interactiveView?.isMouseModeActive == true {
                terminalView?.mouseUp(with: event)
                return
            }

            // Check for plain-text URL click before forwarding to SwiftTerm.
            if let interactive = interactiveView {
                let point = interactive.convert(event.locationInWindow, from: nil)
                if interactive.handleURLClick(at: point) {
                    return
                }
            }
            terminalView?.mouseUp(with: event)

            // Auto-copy selection to clipboard when mouse is released
            if
                let interactive = interactiveView,
                interactive.autoCopyOnSelect,
                interactive.getSelectedTextTrimmed() != nil {
                interactive.copySelectionToClipboard()
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            if interactiveView?.isMouseModeActive == true {
                terminalView?.rightMouseDown(with: event)
            } else {
                super.rightMouseDown(with: event)
            }
        }

        override func rightMouseUp(with event: NSEvent) {
            if interactiveView?.isMouseModeActive == true {
                terminalView?.rightMouseUp(with: event)
            } else {
                super.rightMouseUp(with: event)
            }
        }

        override func rightMouseDragged(with event: NSEvent) {
            if interactiveView?.isMouseModeActive == true {
                terminalView?.rightMouseDragged(with: event)
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            if interactiveView?.isMouseModeActive == true {
                terminalView?.otherMouseDown(with: event)
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            if interactiveView?.isMouseModeActive == true {
                terminalView?.otherMouseUp(with: event)
            }
        }

        override func otherMouseDragged(with event: NSEvent) {
            if interactiveView?.isMouseModeActive == true {
                terminalView?.otherMouseDragged(with: event)
            }
        }
    }

    // MARK: - Terminal Actions

    /// Selectors for terminal actions that can be dispatched via the responder chain.
    @objc
    public protocol TerminalActions {
        func copyAsRichText(_ sender: Any?)
        func copyWithControlSequences(_ sender: Any?)
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

        /// Callback invoked for raw escape sequences (e.g., mouse events) that must be
        /// sent to tmux as-is, bypassing TmuxKey conversion.
        var onRawInput: (@MainActor (Data) -> Void)?

        /// Callback invoked when the terminal title changes (via OSC 0 or OSC 2 escape sequences).
        var onTitleChange: (@MainActor (String) -> Void)?

        /// When false, the terminal won't auto-grab focus on window add or window-becomes-key.
        /// Used in multi-pane layouts where multiple terminals share one window.
        var autoFocusEnabled = true

        var preserveUserScroll = false
        var onResize: ((NSSize) -> Void)?

        /// Accessibility identifier exposed to the AX tree (e.g., "terminal-%5")
        var terminalAccessibilityIdentifier: String?

        /// When set, the terminal dimensions are locked to these values.
        /// SwiftTerm's async processSizeChange (triggered by frame updates)
        /// will be overridden to maintain the locked dimensions.
        var lockedDimensions: (cols: Int, rows: Int)?

        // URL detection state
        private var isOverURL = false
        private var urlPreviewField: NSTextField?
        private var highlightedURLRange: (row: Int, startCol: Int, endCol: Int)?
        private var urlHighlightLayer: CALayer?
        private var urlUnderlineLayers: [CALayer] = []
        private var cachedCellSize: CGSize?
        private var lastMouseGridPosition: (col: Int, row: Int)?

        /// Cached OSC 8 payloads extracted from SwiftTerm cells before clearing.
        /// Structure: [absoluteBufferRow: [col: payloadString]]
        /// Keyed by absolute buffer row so lookups remain correct after scrolling.
        /// We clear SwiftTerm's cell payloads to prevent its own dashed underline rendering,
        /// but cache them here so our URL detection still works.
        private var cachedPayloads: [Int: [Int: String]] = [:]

        private var isFocused = false {
            didSet {
                focusBorderView?.isFocused = isFocused
            }
        }

        // Using nonisolated(unsafe) for notification observer cleanup in deinit
        private nonisolated(unsafe) var windowObservers: [any NSObjectProtocol] = []

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
            for observer in windowObservers {
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
            overlay.onCursorUpdate = { [weak self] event in
                self?.updateCursor(for: event)
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

        /// Returns cached cell size, recalculating only when the font changes.
        var cellSize: CGSize {
            if let cached = cachedCellSize { return cached }
            let size = FontMetrics.calculateCellSize(font: terminalView.font as CTFont)
            cachedCellSize = size
            return size
        }

        // MARK: - First Responder

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            isFocused = true
            // Drive TerminalView's hasFocus so CaretView renders as filled cursor
            // with the correct DECSCUSR style (block/bar/underline). Without this,
            // the caret draws as a hollow rectangle since TerminalView itself never
            // becomes first responder.
            terminalView.hasFocus = true
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            isFocused = false
            terminalView.hasFocus = false
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            // Clean up old observers
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers.removeAll()

            guard let window else { return }

            // Auto-focus when added to a window (disabled in multi-pane layouts
            // where multiple terminals share one window to avoid focus fighting)
            if autoFocusEnabled {
                Task { [weak self] in
                    guard let self else { return }
                    self.window?.makeFirstResponder(self)
                }
            }

            // Re-focus when window becomes key (e.g., after switching apps)
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let window = self.window else { return }
                    if self.autoFocusEnabled {
                        window.makeFirstResponder(self)
                    }
                    // If we're already first responder, restore cursor appearance
                    if window.firstResponder === self {
                        self.terminalView.hasFocus = true
                    }
                }
            })

            // Show hollow cursor when window loses key status
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.terminalView.hasFocus = false
                }
            })
        }

        // MARK: - Copy Support

        /// Whether to automatically copy selected text to the clipboard when the mouse is released.
        var autoCopyOnSelect = false

        /// Returns the selected text with trailing whitespace trimmed from each line.
        func getSelectedTextTrimmed() -> String? {
            guard let text = terminalView.getSelection() else { return nil }
            return Self.trimTrailingWhitespacePerLine(text)
        }

        /// Copies the current selection to the clipboard as plain text (trimmed).
        func copySelectionToClipboard() {
            guard let text = getSelectedTextTrimmed(), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Copies the current selection as rich text (RTF with terminal font/colors/styles).
        @objc
        func copyAsRichText(_ sender: Any?) {
            guard let selectionText = terminalView.getSelection(), !selectionText.isEmpty else { return }

            let terminal = terminalView.getTerminal()
            let baseFont = terminalView.font as NSFont
            let defaultFg = terminalView.nativeForegroundColor
            let defaultBg = terminalView.nativeBackgroundColor
            let colorMapper = TerminalColorMapper(defaultFg: defaultFg, defaultBg: defaultBg)
            let fontMapper = TerminalFontMapper(base: baseFont)

            // Build attributed string for all visible rows.
            // Each row stores its trimmed text and attributed content separately
            // so we can reconstruct with or without newlines for matching.
            var rowTexts: [String] = []
            var rowAttrs: [NSMutableAttributedString] = []

            for row in 0..<terminal.rows {
                guard let line = terminal.getLine(row: row) else { continue }

                let lineText = line.translateToString(trimRight: true)
                let rowAttr = NSMutableAttributedString()
                var charIndex = lineText.startIndex
                var col = 0

                while col < terminal.cols, charIndex < lineText.endIndex {
                    let cd = line[col]
                    let charWidth = Int(max(cd.width, 1))

                    let char = lineText[charIndex]
                    let charStr = String(char)

                    let attrs = buildAttributes(
                        for: cd.attribute,
                        fontMapper: fontMapper,
                        colorMapper: colorMapper,
                        defaultFg: defaultFg,
                        defaultBg: defaultBg
                    )

                    rowAttr.append(NSAttributedString(string: charStr, attributes: attrs))

                    col += charWidth
                    charIndex = lineText.index(after: charIndex)
                }

                rowTexts.append(lineText)
                rowAttrs.append(rowAttr)
            }

            // Join rows with newlines to match getSelection() output.
            // Newlines carry the base font so RTF renderers use consistent line spacing.
            let newlineAttrs: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: defaultFg,
                .backgroundColor: defaultBg,
            ]
            let fullPlain = rowTexts.joined(separator: "\n")
            let fullAttributed = NSMutableAttributedString()
            for (index, rowAttr) in rowAttrs.enumerated() {
                if index > 0 {
                    fullAttributed.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
                }
                fullAttributed.append(rowAttr)
            }

            // Find selection within the full terminal text and extract the formatted portion.
            // Search backwards because selections are typically near the bottom of the
            // visible buffer. SwiftTerm's selection coordinates are internal to the package,
            // so string matching is the best available approach. If identical text appears
            // multiple times, the last occurrence (closest to the cursor) is matched.
            let attributed: NSAttributedString
            if let range = fullPlain.range(of: selectionText, options: .backwards) {
                let nsRange = NSRange(range, in: fullPlain)
                attributed = fullAttributed.attributedSubstring(from: nsRange)
            } else {
                // Fallback: apply default formatting to selection text
                attributed = NSAttributedString(
                    string: selectionText,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: defaultFg,
                        .backgroundColor: defaultBg,
                    ]
                )
            }

            // Trim trailing whitespace per line from the attributed string
            let trimmed = Self.trimTrailingWhitespaceFromAttributedString(attributed)
            let plainText = Self.trimTrailingWhitespacePerLine(selectionText)

            guard let rtfData = trimmed.rtf(from: NSRange(location: 0, length: trimmed.length)) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(rtfData, forType: .rtf)
            NSPasteboard.general.setString(plainText, forType: .string)
        }

        /// Copies the current selection with ANSI control sequences preserved.
        @objc
        func copyWithControlSequences(_ sender: Any?) {
            guard let selectionText = terminalView.getSelection(), !selectionText.isEmpty else { return }

            let terminal = terminalView.getTerminal()

            // Build per-row data with trimmed text matching getSelection() output
            var rowTexts: [String] = []
            var rowCells: [[(Character, Attribute)]] = []

            for row in 0..<terminal.rows {
                guard let line = terminal.getLine(row: row) else { continue }

                let lineText = line.translateToString(trimRight: true)
                var cells: [(Character, Attribute)] = []
                var charIndex = lineText.startIndex
                var col = 0

                while col < terminal.cols, charIndex < lineText.endIndex {
                    let cd = line[col]
                    let charWidth = Int(max(cd.width, 1))
                    let char = lineText[charIndex]
                    cells.append((char, cd.attribute))
                    col += charWidth
                    charIndex = lineText.index(after: charIndex)
                }

                rowTexts.append(lineText)
                rowCells.append(cells)
            }

            let fullPlain = rowTexts.joined(separator: "\n")

            // Find the selection range within the full text (search backwards — see copyAsRichText comment)
            guard let matchRange = fullPlain.range(of: selectionText, options: .backwards) else {
                // Fallback: copy plain text without sequences
                let trimmed = Self.trimTrailingWhitespacePerLine(selectionText)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
                return
            }

            // Map the matched character range back to row/col positions
            let startOffset = fullPlain.distance(from: fullPlain.startIndex, to: matchRange.lowerBound)
            let endOffset = fullPlain.distance(from: fullPlain.startIndex, to: matchRange.upperBound)

            // Build ANSI-escaped text
            var result = ""
            var prevAttr: Attribute?
            var globalOffset = 0

            for (rowIndex, rowText) in rowTexts.enumerated() {
                let rowStart = globalOffset
                let rowEnd = globalOffset + rowText.count

                if rowIndex > 0 {
                    globalOffset += 1 // account for \n separator
                }

                // Check overlap with selection
                let selStart = max(startOffset, rowStart)
                let selEnd = min(endOffset, rowEnd)

                if selStart < selEnd {
                    // This row has selected content
                    let localStart = selStart - rowStart
                    let localEnd = selEnd - rowStart
                    let cells = rowCells[rowIndex]

                    if !result.isEmpty {
                        result += "\n"
                    }

                    for i in localStart..<min(localEnd, cells.count) {
                        let (char, attr) = cells[i]

                        // Only emit SGR when attributes change
                        if attr != prevAttr {
                            result += Self.sgrSequence(for: attr)
                            prevAttr = attr
                        }
                        result.append(char)
                    }
                }

                globalOffset = rowEnd
                if rowIndex < rowTexts.count - 1 {
                    globalOffset += 1 // \n
                }
            }

            // Reset at end
            if prevAttr != nil {
                result += "\u{1B}[0m"
            }

            // Trim trailing whitespace per line
            let trimmed = Self.trimTrailingWhitespacePerLine(result)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
        }

        /// Builds an SGR escape sequence for the given terminal attribute.
        static func sgrSequence(for attr: Attribute) -> String {
            var params = ["0"] // reset first
            let style = attr.style

            if style.contains(.bold) { params.append("1") }
            if style.contains(.dim) { params.append("2") }
            if style.contains(.italic) { params.append("3") }
            if style.contains(.underline) { params.append("4") }
            if style.contains(.blink) { params.append("5") }
            if style.contains(.inverse) { params.append("7") }
            if style.contains(.invisible) { params.append("8") }
            if style.contains(.crossedOut) { params.append("9") }

            // Foreground color
            params.append(contentsOf: sgrColorParams(attr.fg, isFg: true))

            // Background color
            params.append(contentsOf: sgrColorParams(attr.bg, isFg: false))

            // Underline color (SGR 58)
            if let ulColor = attr.underlineColor {
                switch ulColor {
                case let .ansi256(code):
                    params.append(contentsOf: ["58", "5", "\(code)"])
                case let .trueColor(r, g, b):
                    params.append(contentsOf: ["58", "2", "\(r)", "\(g)", "\(b)"])
                default:
                    break
                }
            }

            return "\u{1B}[\(params.joined(separator: ";"))m"
        }

        /// Returns SGR parameters for a foreground or background color.
        static func sgrColorParams(_ color: Attribute.Color, isFg: Bool) -> [String] {
            switch color {
            case .defaultColor,
                 .defaultInvertedColor:
                return [] // default color, no params needed (handled by reset)
            case let .ansi256(code):
                if code < 8 {
                    // Standard colors: 30-37 fg, 40-47 bg
                    return ["\((isFg ? 30 : 40) + Int(code))"]
                } else if code < 16 {
                    // Bright colors: 90-97 fg, 100-107 bg
                    return ["\((isFg ? 90 : 100) + Int(code) - 8)"]
                } else {
                    // Extended 256-color: 38;5;N or 48;5;N
                    return [isFg ? "38" : "48", "5", "\(code)"]
                }
            case let .trueColor(r, g, b):
                return [isFg ? "38" : "48", "2", "\(r)", "\(g)", "\(b)"]
            }
        }

        func buildAttributes(
            for attr: Attribute,
            fontMapper: TerminalFontMapper,
            colorMapper: TerminalColorMapper,
            defaultFg: NSColor,
            defaultBg: NSColor
        ) -> [NSAttributedString.Key: Any] {
            let style = attr.style
            var result: [NSAttributedString.Key: Any] = [:]

            // Font (bold, italic, bold+italic)
            result[.font] = fontMapper.font(for: style)

            // Colors
            var fgColor = colorMapper.mapColor(attr.fg, isFg: true, isBold: style.contains(.bold))
            var bgColor = colorMapper.mapColor(attr.bg, isFg: false, isBold: false)

            if style.contains(.inverse) {
                swap(&fgColor, &bgColor)
            }
            if style.contains(.dim) {
                fgColor = fgColor.withAlphaComponent(0.5)
            }

            result[.foregroundColor] = fgColor
            result[.backgroundColor] = bgColor

            // Underline
            if style.contains(.underline) {
                result[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let ulColor = attr.underlineColor {
                    result[.underlineColor] = colorMapper.mapColor(ulColor, isFg: true, isBold: false)
                }
            }

            // Strikethrough
            if style.contains(.crossedOut) {
                result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result[.strikethroughColor] = fgColor
            }

            return result
        }

        /// Trims trailing whitespace from each line of an attributed string.
        static func trimTrailingWhitespaceFromAttributedString(
            _ attributedString: NSAttributedString
        ) -> NSAttributedString {
            let nsString = attributedString.string as NSString
            let result = NSMutableAttributedString()

            // Split on newlines, tracking UTF-16 offsets for NSRange
            var offset = 0
            let newlineSet = CharacterSet.newlines
            while offset < nsString.length {
                let remaining = NSRange(location: offset, length: nsString.length - offset)
                let newlineRange = nsString.rangeOfCharacter(from: newlineSet, range: remaining)
                let lineEnd = newlineRange.location == NSNotFound
                    ? nsString.length
                    : newlineRange.location

                // Trim trailing spaces/tabs from this line
                var trimmedEnd = lineEnd
                while trimmedEnd > offset {
                    let ch = nsString.character(at: trimmedEnd - 1)
                    if ch == 0x20 || ch == 0x09 {
                        trimmedEnd -= 1
                    } else {
                        break
                    }
                }

                if trimmedEnd > offset {
                    result.append(attributedString.attributedSubstring(from: NSRange(location: offset, length: trimmedEnd - offset)))
                }

                if newlineRange.location != NSNotFound {
                    // Preserve the original newline's attributes (font, colors)
                    result.append(attributedString.attributedSubstring(from: newlineRange))
                    offset = newlineRange.location + newlineRange.length
                } else {
                    break
                }
            }

            return result
        }

        /// Trims trailing whitespace from each line while preserving line structure.
        static func trimTrailingWhitespacePerLine(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var s = line
                    while s.last?.isWhitespace == true {
                        s = s.dropLast()
                    }
                    return String(s)
                }
                .joined(separator: "\n")
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
                if terminalView.getSelection() != nil {
                    copySelectionToClipboard()
                    return true
                }
                return false

            default:
                return false
            }
        }

        override func keyDown(with event: NSEvent) {
            terminalView.keyDown(with: event)
        }

        override func flagsChanged(with event: NSEvent) {
            super.flagsChanged(with: event)
            updateCursor(for: event)
        }

        // MARK: - URL Detection

        /// Bridges SwiftTerm's `Terminal` to the closures expected by `TerminalURLDetector`.
        /// Uses cached payloads (extracted before clearing) instead of live cell payloads.
        /// Converts viewport rows to absolute buffer rows for cache lookup.
        private func urlClosures(for terminal: Terminal) -> (
            lineText: (Int) -> String?,
            cellPayload: (Int, Int) -> String?
        ) {
            let payloads = cachedPayloads
            let yDisp = terminal.buffer.yDisp
            return (
                lineText: { terminal.getLine(row: $0)?.translateToString(trimRight: true) },
                cellPayload: { col, row in payloads[row + yDisp]?[col] }
            )
        }

        /// Scans ALL terminal buffer lines for OSC 8 payloads, merges them into the cache, then clears them.
        /// We cache payloads so our URL detection works, but clear them from SwiftTerm's cells
        /// to prevent SwiftTerm from rendering its own dashed underlines.
        /// Merges rather than replaces so payloads from earlier feeds (already cleared) are preserved.
        private func extractAndClearPayloads() {
            let terminal = terminalView.getTerminal()
            // TinyAtom.empty is internal, but TinyAtom is a single UInt16 struct —
            // empty has code 0 which makes CharData.hasPayload return false.
            assert(MemoryLayout<TinyAtom>.size == MemoryLayout<UInt16>.size, "TinyAtom layout changed — unsafeBitCast assumption is invalid")
            let emptyAtom = unsafeBitCast(UInt16(0), to: TinyAtom.self)
            let cols = terminal.cols
            let totalLines = terminal.buffer.yDisp + terminal.rows

            for absoluteRow in 0..<totalLines {
                guard let line = terminal.getScrollInvariantLine(row: absoluteRow) else { continue }
                for col in 0..<cols {
                    var cd = line[col]
                    if cd.hasPayload {
                        if let payload = cd.getPayload() as? String, !payload.isEmpty {
                            if cachedPayloads[absoluteRow] == nil {
                                cachedPayloads[absoluteRow] = [:]
                            }
                            cachedPayloads[absoluteRow]?[col] = payload
                        }
                        cd.setPayload(atom: emptyAtom)
                        line[col] = cd
                    }
                }
            }

            // Prune entries for lines that have been trimmed from the circular buffer
            let minRow = cachedPayloads.keys.min() ?? 0
            if minRow < totalLines {
                for row in minRow..<totalLines where cachedPayloads[row] != nil {
                    if terminal.getScrollInvariantLine(row: row) == nil {
                        cachedPayloads.removeValue(forKey: row)
                    } else {
                        break // Lines are contiguous; once we find a valid one, the rest are valid
                    }
                }
            }
        }

        /// Converts a point in this view's coordinate space to a viewport grid position (col, row).
        /// The returned row is a viewport row suitable for `Terminal.getLine(row:)`.
        private func gridPosition(for point: NSPoint) -> (col: Int, row: Int)? {
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

        private func handleMouseMoved(_ event: NSEvent) {
            // When mouse mode is active, the terminal app owns mouse interaction.
            // Clear any stale highlights and skip URL detection.
            if isMouseModeActive {
                removeURLHighlight()
                removeURLPreview()
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            updateURLHighlight(at: point)
        }

        private func handleMouseExited() {
            lastMouseGridPosition = nil
            isOverURL = false
            removeURLHighlight()
            removeURLPreview()
        }

        private func updateURLHighlight(at point: NSPoint) {
            guard let pos = gridPosition(for: point) else {
                lastMouseGridPosition = nil
                isOverURL = false
                removeURLHighlight()
                removeURLPreview()
                return
            }

            // Skip redundant detection when mouse stays in the same cell
            if let last = lastMouseGridPosition, last.col == pos.col, last.row == pos.row {
                return
            }
            lastMouseGridPosition = pos

            let terminal = terminalView.getTerminal()
            let closures = urlClosures(for: terminal)
            let urls = TerminalURLDetector.detectURLs(
                row: pos.row,
                cols: terminal.cols,
                lineText: closures.lineText,
                cellPayload: closures.cellPayload
            )
            if let detected = urls.first(where: { pos.col >= $0.startCol && pos.col < $0.endCol }) {
                let newRange = (row: pos.row, startCol: detected.startCol, endCol: detected.endCol)
                if
                    highlightedURLRange?.row == newRange.row,
                    highlightedURLRange?.startCol == newRange.startCol,
                    highlightedURLRange?.endCol == newRange.endCol {
                    return // Already highlighting this URL
                }
                highlightedURLRange = newRange
                showURLHighlight(row: pos.row, startCol: detected.startCol, endCol: detected.endCol)
                showURLPreview(detected.url)
                isOverURL = true
            } else {
                isOverURL = false
                removeURLHighlight()
                removeURLPreview()
            }
        }

        private func showURLHighlight(row: Int, startCol: Int, endCol: Int) {
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

        /// Whether the terminal application has requested mouse event tracking.
        var isMouseModeActive: Bool {
            terminalView.getTerminal().mouseMode != .off
        }

        /// Called by the system's cursor tracking when the cursor enters/moves within the view.
        /// Sets the cursor based on mouse mode and whether the mouse is over a detected URL.
        /// When mouse mode is active but Shift is held, shows iBeam to hint that text
        /// selection is available.
        private func updateCursor(for event: NSEvent) {
            if isMouseModeActive {
                if event.modifierFlags.contains(.shift) {
                    NSCursor.iBeam.set()
                } else {
                    NSCursor.arrow.set()
                }
            } else if isOverURL {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }

        /// Called by the scroll overlay on click — opens URL if one is at the click position.
        fileprivate func handleURLClick(at point: NSPoint) -> Bool {
            guard let pos = gridPosition(for: point) else { return false }
            let terminal = terminalView.getTerminal()
            let closures = urlClosures(for: terminal)
            if
                let url = TerminalURLDetector.urlAt(
                    col: pos.col,
                    row: pos.row,
                    cols: terminal.cols,
                    lineText: closures.lineText,
                    cellPayload: closures.cellPayload
                ),
                let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
                return true
            }
            return false
        }

        // MARK: - URL Underlines

        /// Scans visible rows for URLs and draws persistent underline decorations.
        /// Called when terminal content changes or scrolls.
        private func updateURLUnderlines() {
            for layer in urlUnderlineLayers {
                layer.removeFromSuperlayer()
            }
            urlUnderlineLayers.removeAll()

            let terminal = terminalView.getTerminal()
            guard cellSize.width > 0, cellSize.height > 0 else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let closures = urlClosures(for: terminal)
            for row in 0..<terminal.rows {
                let urls = TerminalURLDetector.detectURLs(
                    row: row,
                    cols: terminal.cols,
                    lineText: closures.lineText,
                    cellPayload: closures.cellPayload
                )
                for url in urls {
                    let x = CGFloat(url.startCol) * cellSize.width - horizontalOffset
                    // Position underline near cell bottom (NSView: origin at bottom-left)
                    let y = terminalView.frame.height - CGFloat(row + 1) * cellSize.height
                    let width = CGFloat(url.endCol - url.startCol) * cellSize.width

                    let underline = CALayer()
                    underline.backgroundColor = NSColor.linkColor.withAlphaComponent(0.9).cgColor
                    underline.frame = CGRect(x: x, y: y, width: width, height: 2)
                    terminalView.layer?.addSublayer(underline)
                    urlUnderlineLayers.append(underline)
                }
            }

            CATransaction.commit()
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
            // When dimensions are locked (tmux pane), use the optimal height
            // to avoid triggering SwiftTerm's processSizeChange which would
            // recalculate rows and corrupt the terminal buffer. Position the
            // terminal at the top of the container (high y in AppKit coords).
            let height: CGFloat
            let originY: CGFloat
            if lockedDimensions != nil {
                height = size.height
                originY = bounds.height - height
            } else {
                height = bounds.height
                originY = 0
            }
            terminalView.frame = NSRect(x: -horizontalOffset, y: originY, width: size.width, height: height)

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
            // When dimensions are locked, don't change the terminal frame
            // height — this triggers SwiftTerm's processSizeChange which
            // corrupts the buffer. Keep it at optimal height, pinned to top.
            if lockedDimensions == nil {
                terminalView.frame.size.height = bounds.height
            } else {
                terminalView.frame.origin.y = bounds.height - terminalView.frame.size.height
            }
            updateHorizontalScroller()
            updateURLUnderlines()
            onResize?(frame.size)
        }

        // MARK: - TerminalView Forwarding

        var font: NSFont {
            get { terminalView.font }
            set {
                terminalView.font = newValue
                cachedCellSize = nil
            }
        }

        var customBlockGlyphs: Bool {
            get { terminalView.customBlockGlyphs }
            set { terminalView.customBlockGlyphs = newValue }
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

        // MARK: - Accessibility

        override func accessibilityValue() -> Any? {
            let terminal = terminalView.getTerminal()
            var lines: [String] = []
            for row in 0..<terminal.rows {
                guard let line = terminal.getLine(row: row) else { continue }
                lines.append(line.translateToString(trimRight: true))
            }
            return lines.joined(separator: "\n")
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            .textArea
        }

        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityIdentifier() -> String {
            terminalAccessibilityIdentifier ?? "terminal"
        }

        func feed(byteArray: ArraySlice<UInt8>) {
            terminalView.feed(byteArray: byteArray)
            extractAndClearPayloads()
            needsLayout = true
        }

        func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
            let savedPosition = scrollPosition
            // Consider "at bottom" if:
            // - Position >= 0.999 (actually at bottom)
            // - Position <= 0.001 (no scrollback yet, or at very top)
            let wasAtExtreme = savedPosition >= 0.999 || savedPosition <= 0.001
            terminalView.feed(byteArray: bytes)
            extractAndClearPayloads()
            if preserveUserScroll, !wasAtExtreme {
                terminalView.scroll(toPosition: savedPosition)
            }
            needsLayout = true
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

    // MARK: - TerminalActions

    extension InteractiveTerminalView: @preconcurrency TerminalActions { }

    // MARK: - TerminalViewDelegate

    extension InteractiveTerminalView: @preconcurrency TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Defense-in-depth: DA queries are stripped from the feed in PipePaneReader,
            // but catch any remaining auto-responses (cursor position reports, terminal
            // parameter reports) that SwiftTerm may still generate.
            if TerminalResponseFilter.isTerminalResponse(data) { return }

            // Mouse escape sequences (SGR, X10) can't be parsed by TmuxKey.from(bytes:)
            // because the CSI parser doesn't handle private-use parameter prefixes like '<'.
            // Send them as raw bytes to tmux via send-keys -H.
            // Drop motion events (bit 5 set) — SwiftTerm's own tracking areas generate
            // these even though the overlay doesn't forward mouseMoved, and some apps
            // misinterpret them as click events.
            if TerminalResponseFilter.isMouseEscapeSequence(data) {
                if TerminalResponseFilter.isMouseMotionEvent(data) { return }
                onRawInput?(Data(data))
                return
            }

            // Convert raw bytes to TmuxKey representations
            let keys = TmuxKey.from(bytes: Data(data))
            guard !keys.isEmpty else { return }
            onInput?(keys)
        }

        func scrolled(source: TerminalView, position: Double) {
            needsLayout = true
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            onTitleChange?(title)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // When dimensions are locked (connected to a tmux pane), SwiftTerm's
            // processSizeChange may recalculate rows from the frame height after
            // a layout pass, overriding our locked dimensions. Re-apply them here.
            if
                let locked = lockedDimensions,
                newCols != locked.cols || newRows != locked.rows {
                source.getTerminal().resize(cols: locked.cols, rows: locked.rows)
            }
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
                let trimmed = InteractiveTerminalView.trimTrailingWhitespacePerLine(string)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            needsLayout = true
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // No-op - iTerm2 specific sequences not needed
        }
    }

    // MARK: - Rich Text Copy Helpers

    /// Maps SwiftTerm `Attribute.Color` values to `NSColor` for rich text copy.
    ///
    /// Builds an in-memory ANSI 256-color palette matching SwiftTerm's default
    /// `terminalAppColors` base with the standard 6×6×6 cube and greyscale ramp.
    struct TerminalColorMapper {
        let defaultFg: NSColor
        let defaultBg: NSColor
        private let palette: [NSColor]

        init(defaultFg: NSColor, defaultBg: NSColor) {
            self.defaultFg = defaultFg
            self.defaultBg = defaultBg
            self.palette = Self.buildPalette()
        }

        func mapColor(_ color: Attribute.Color, isFg: Bool, isBold: Bool) -> NSColor {
            switch color {
            case .defaultColor:
                return isFg ? defaultFg : defaultBg
            case .defaultInvertedColor:
                return isFg ? defaultBg : defaultFg
            case let .ansi256(code):
                // Bold text with standard colors (0-7) uses bright variants (8-15)
                let idx = (code < 8 && isBold) ? Int(code) + 8 : Int(code)
                return palette[min(idx, 255)]
            case let .trueColor(r, g, b):
                return NSColor(
                    srgbRed: CGFloat(r) / 255,
                    green: CGFloat(g) / 255,
                    blue: CGFloat(b) / 255,
                    alpha: 1
                )
            }
        }

        /// Builds the standard 256-color ANSI palette (matching SwiftTerm's terminalAppColors default).
        private static func buildPalette() -> [NSColor] {
            // First 16: SwiftTerm's terminalAppColors
            let base16: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
                (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
                (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
                (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
            ]

            var colors: [NSColor] = base16.map { r, g, b in
                NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            }

            // 216 color cube (indices 16-231)
            let v: [CGFloat] = [0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF].map { CGFloat($0) / 255 }
            for i in 0..<216 {
                colors.append(NSColor(
                    srgbRed: v[(i / 36) % 6],
                    green: v[(i / 6) % 6],
                    blue: v[i % 6],
                    alpha: 1
                ))
            }

            // 24 greyscale (indices 232-255)
            for i in 0..<24 {
                let c = CGFloat(8 + i * 10) / 255
                colors.append(NSColor(srgbRed: c, green: c, blue: c, alpha: 1))
            }

            return colors
        }
    }

    /// Resolves terminal `CharacterStyle` flags to the appropriate `NSFont` variant.
    struct TerminalFontMapper {
        let normal: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont

        init(base: NSFont) {
            let fm = NSFontManager.shared
            self.normal = base
            self.bold = fm.convert(base, toHaveTrait: .boldFontMask)
            self.italic = fm.convert(base, toHaveTrait: .italicFontMask)
            self.boldItalic = fm.convert(base, toHaveTrait: [.boldFontMask, .italicFontMask])
        }

        func font(for style: CharacterStyle) -> NSFont {
            let isBold = style.contains(.bold)
            let isItalic = style.contains(.italic)
            if isBold && isItalic { return boldItalic }
            if isBold { return bold }
            if isItalic { return italic }
            return normal
        }
    }
#endif
