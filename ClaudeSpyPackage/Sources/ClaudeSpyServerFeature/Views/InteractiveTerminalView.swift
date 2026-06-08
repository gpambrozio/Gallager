#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Dependencies
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

    // MARK: - Right Edge Background Fill

    /// Paints the strip between the rightmost terminal cell and the view's right
    /// edge with each visible row's trailing-cell background color.
    ///
    /// SwiftTerm reserves ~1 column of width for its (unused) internal legacy
    /// scroller, so the drawn cells stop short of the view's right edge by that
    /// margin. Full-pane-width background bands — e.g. Codex's filled prompt
    /// panels — then look truncated: the cells are filled, but the reserved
    /// margin shows the default terminal background. This overlay extends each
    /// row's trailing background into the margin so bands reach the edge, exactly
    /// as they do in a terminal without a reserved scroller (iTerm, Terminal.app).
    ///
    /// The view is non-interactive (events pass through to the terminal) and is
    /// flipped so row 0 sits at the top, matching the terminal's row order.
    final private class RightEdgeBackgroundView: NSView {
        private var fills: [(rect: CGRect, color: CGColor)] = []

        override var isFlipped: Bool { true }

        // Transparent to hit-testing so mouse/scroll events reach the terminal.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setFills(_ fills: [(rect: CGRect, color: CGColor)]) {
            self.fills = fills
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            for fill in fills where fill.rect.intersects(dirtyRect) {
                ctx.setFillColor(fill.color)
                ctx.fill(fill.rect)
            }
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

        /// Last terminal cell that generated a drag SGR sequence.
        /// Used to suppress redundant events when the cursor stays in the same cell.
        private var lastDragPosition: (col: Int, row: Int)?

        override var acceptsFirstResponder: Bool {
            false
        }

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
            if
                let interactive = interactiveView,
                interactive.isMouseModeActive,
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
            // In mouse mode, suppress the press if it lands on a URL we'd
            // intercept in `mouseUp` (file/http/https/ftp). Otherwise SwiftTerm
            // forwards a mouse-press SGR sequence to the terminal app (e.g.
            // Claude Code), which can open the link from the press event
            // before our `handleURLClick` runs — Claude Code in particular
            // shells out to `open(1)` for OSC 8 hyperlinks, racing past the
            // `browserLinkBehavior` prompt.
            if
                let interactive = interactiveView,
                interactive.isMouseModeActive,
                interactive.isClickOnInterceptableURL(
                    at: interactive.convert(event.locationInWindow, from: nil),
                    allowedSchemes: TerminalURLDetector.defaultAllowedSchemes.union(["file"])
                ) {
                onMouseDown?()
                return
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
                // Skip if the cursor hasn't moved to a new cell — mouseDragged
                // fires at display refresh rate and each onRawInput spawns a
                // tmux subprocess, so deduplication matters.
                if let last = lastDragPosition, last.col == col, last.row == row {
                    return
                }
                lastDragPosition = (col, row)

                // SGR drag: button 32 (left button + motion bit 5)
                // Format: ESC [ < 32 ; col ; row M  (1-indexed coordinates)
                let seq = "\u{1b}[<32;\(col + 1);\(row + 1)M"
                interactive.onRawInput?(Data(seq.utf8))
                return
            }
            terminalView?.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            lastDragPosition = nil

            if let interactive = interactiveView {
                let point = interactive.convert(event.locationInWindow, from: nil)
                // Intercept the same scheme set in both modes: in mouse mode
                // the matching `mouseDown` carve-out has already suppressed
                // the press for these URLs, so the TUI app never saw the
                // click. Routing through `handleURLClick` then `onOpenURL`
                // gives the host's `browserLinkBehavior` policy authority
                // over OSC 8 hyperlinks rendered by TUIs like Claude Code.
                let allowed = TerminalURLDetector.defaultAllowedSchemes.union(["file"])
                if interactive.handleURLClick(at: point, allowedSchemes: allowed) {
                    return
                }
            }

            // No matching URL at the click point. In mouse mode, the terminal
            // app owns the click — forward to SwiftTerm and skip auto-copy.
            if interactiveView?.isMouseModeActive == true {
                terminalView?.mouseUp(with: event)
                return
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
        private var rightEdgeFillView: RightEdgeBackgroundView?
        private var terminalWidth: CGFloat = 0
        private var horizontalOffset: CGFloat = 0

        /// Callback invoked when the user types. The keys are ready for relay transmission.
        var onInput: (@MainActor ([TmuxKey]) -> Void)?

        /// Callback invoked for raw escape sequences (e.g., mouse events) that must be
        /// sent to tmux as-is, bypassing TmuxKey conversion.
        var onRawInput: (@MainActor (Data) -> Void)?

        /// Callback invoked when the user pastes an image (Cmd+V with image clipboard
        /// contents). When set, the terminal hands the image off to the host instead
        /// of sending Ctrl+V locally. Used by the remote terminal mirror to forward
        /// images over the relay so the host's foreground app can paste them.
        ///
        /// Return-value contract:
        /// - `true`: handler consumed the paste; the terminal does nothing further.
        /// - `false`: fall back to the local Ctrl+V flow — **not** "skip the paste".
        ///   The local fallback sends `Ctrl+V` into the pane, which makes the
        ///   in-pane app read the *host's* pasteboard. Do not return `false` to
        ///   signal a forward failure: the user would silently get a Ctrl+V into
        ///   the pane against the wrong (unmodified host) clipboard. Failures
        ///   should be surfaced by the handler itself; always return `true` once
        ///   the handler has taken responsibility for the paste.
        var onImagePaste: (@MainActor (ClipboardImage) -> Bool)?

        /// Callback invoked when the user drops files from Finder onto the
        /// terminal. The wrapper view extracts file URLs from the dragging
        /// pasteboard and hands them to this callback so the local pane can
        /// paste the paths via tmux's bracketed-paste buffer, and the remote
        /// pane can ship the bytes to its host.
        var onFileDrop: (@MainActor ([URL]) -> Void)?

        /// Callback invoked when the terminal title changes (via OSC 0 or OSC 2 escape sequences).
        var onTitleChange: (@MainActor (String) -> Void)?

        /// Callback invoked when the user clicks a URL in the terminal. The
        /// callback should return `true` if it handled the URL (and the
        /// terminal view should do nothing further) or `false` to fall back to
        /// `NSWorkspace.shared.open(_:)`. When the callback is `nil`, all URLs
        /// are forwarded to `NSWorkspace`.
        var onOpenURL: (@MainActor (URL) -> Bool)?

        /// When false, the terminal won't auto-grab focus on window add or window-becomes-key.
        /// Used in multi-pane layouts where multiple terminals share one window.
        var autoFocusEnabled = true

        /// Fires whenever this view becomes the window's first responder
        /// (mouse click, programmatic, tabbing). Used to propagate focus back
        /// to tmux via `select-pane` so external clients see the same active pane.
        var onBecomeFirstResponder: (@MainActor () -> Void)?

        var preserveUserScroll = false
        var onResize: ((NSSize) -> Void)?

        /// Accessibility identifier exposed to the AX tree (e.g., "terminal-%5")
        var terminalAccessibilityIdentifier: String?

        /// When set, the terminal dimensions are locked to these values.
        /// SwiftTerm's async processSizeChange (triggered by frame updates)
        /// will be overridden to maintain the locked dimensions.
        var lockedDimensions: (cols: Int, rows: Int)?

        /// When true, a prompt editor overlay is active above this terminal.
        /// Keyboard events and auto-focus are suppressed so the editor gets input.
        var isEditorActive = false

        // URL detection state
        private var isOverURL = false
        private var urlPreviewField: NSTextField?
        private var highlightedURLRange: (row: Int, startCol: Int, endCol: Int)?
        private var urlHighlightLayer: CALayer?
        private var urlUnderlineLayers: [CALayer] = []
        private var cachedCellSize: CGSize?
        private var lastMouseGridPosition: (col: Int, row: Int)?

        /// OSC 8 hyperlink payload cache, mirrored from SwiftTerm cells before
        /// we clear them to suppress SwiftTerm's own dashed underline rendering.
        /// See `TerminalPayloadCache` for the full rationale.
        private let payloadCache = TerminalPayloadCache()

        private var isFocused = false {
            didSet {
                focusBorderView?.isFocused = isFocused
            }
        }

        /// Using nonisolated(unsafe) for notification observer cleanup in deinit
        private nonisolated(unsafe) var windowObservers: [any NSObjectProtocol] = []

        override init(frame: NSRect) {
            self.terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size))
            super.init(frame: frame)

            wantsLayer = true
            layer?.masksToBounds = true
            terminalView.autoresizingMask = []
            terminalView.terminalDelegate = self
            addSubview(terminalView)
            setupRightEdgeFill()
            setupScrollOverlay()
            setupHorizontalScroller()
            setupFocusBorder()
            registerForDraggedTypes([.fileURL])
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

        private func setupRightEdgeFill() {
            let fillView = RightEdgeBackgroundView(frame: bounds)
            fillView.autoresizingMask = [.width, .height]
            addSubview(fillView)
            rightEdgeFillView = fillView
        }

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

        override var acceptsFirstResponder: Bool {
            true
        }

        override func becomeFirstResponder() -> Bool {
            isFocused = true
            // Drive TerminalView's hasFocus so CaretView renders as filled cursor
            // with the correct DECSCUSR style (block/bar/underline). Without this,
            // the caret draws as a hollow rectangle since TerminalView itself never
            // becomes first responder.
            terminalView.hasFocus = true
            onBecomeFirstResponder?()
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
            // where multiple terminals share one window to avoid focus fighting,
            // and when the prompt editor overlay is active)
            if autoFocusEnabled, !isEditorActive {
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
                    if self.autoFocusEnabled, !self.isEditorActive {
                        // In a multi-pane window every pane registers this
                        // observer; if a sibling terminal already holds first
                        // responder we must not steal it. The observers run
                        // in an unspecified order and the last writer wins,
                        // so without this guard the tmux-active pane keeps
                        // overriding the user's explicit click.
                        let currentResponder = window.firstResponder
                        let siblingHasFocus =
                            currentResponder !== self &&
                            currentResponder is InteractiveTerminalView
                        if !siblingHasFocus {
                            window.makeFirstResponder(self)
                        }
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
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(text)
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
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setRichText(rtfData, plainText)
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
                @Dependency(ClipboardClient.self) var clipboard
                clipboard.setString(trimmed)
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

            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(trimmed)
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
            // Don't intercept keys when the prompt editor overlay is active
            guard !isEditorActive else { return false }

            // performKeyEquivalent is dispatched depth-first across every view in
            // the window — not just the first responder — and the first view that
            // returns true consumes the event. In a multi-pane layout, that means
            // any sibling pane could claim Cmd+V or Cmd+C and route input to the
            // wrong tmux target. Only act when this pane actually has focus.
            guard isFocused else { return false }

            guard event.modifierFlags.contains(.command) else {
                return false
            }

            switch event.charactersIgnoringModifiers {
            case "v":
                // Handle Cmd+V paste
                @Dependency(ClipboardClient.self) var clipboard

                // If clipboard has text, send it directly to tmux
                if let clipboardString = clipboard.getString(), !clipboardString.isEmpty {
                    onInput?([.text(clipboardString)])
                    return true
                }

                // If clipboard has an image, hand it off to the remote-paste
                // path when set (viewer of a remote host) — otherwise fall back
                // to the local Ctrl+V flow that lets the in-pane terminal app
                // read the host's pasteboard directly.
                if let image = clipboard.getImage() {
                    if let onImagePaste, onImagePaste(image) {
                        return true
                    }
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

        // MARK: - File Drop (Drag from Finder)

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            // Don't promise a copy if there's nothing wired to receive it
            // — otherwise AppKit would show a copy cursor that's about to
            // be rejected by `prepareForDragOperation`.
            guard
                onFileDrop != nil,
                sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            else { return [] }
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            // `draggingUpdated` fires repeatedly during a drag; bail out fast
            // when no drop handler is wired so we don't pay for the pasteboard
            // class read on every event. `draggingEntered` repeats this guard
            // — the explicit early-return here just keeps the hot path from
            // depending on that internal detail.
            guard onFileDrop != nil else { return [] }
            return draggingEntered(sender)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            // No callback wired (no pane yet) — refuse to accept the drop so
            // AppKit shows the user the "rejected" animation instead of
            // silently absorbing the drag.
            onFileDrop != nil
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard
                let onFileDrop,
                let urls = sender.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL],
                !urls.isEmpty
            else { return false }
            onFileDrop(urls)
            return true
        }

        /// Test hook: simulate a file drop without going through AppKit's
        /// dragging machinery. Used by `TestAccessibilityServer` so E2E
        /// scenarios can exercise the drop flow even though they can't drag
        /// from a real Finder.
        func simulateFileDrop(_ urls: [URL]) {
            onFileDrop?(urls)
        }

        override func keyDown(with event: NSEvent) {
            guard !isEditorActive else { return }

            // SwiftTerm's legacy keyDown path dispatches both Enter and
            // Shift+Enter through `insertNewline:`, collapsing the modifier
            // to plain `\r`. SwiftTerm only preserves the modifier when the
            // inner app pushes kitty mode, which can't happen here because
            // the inner app talks to tmux's PTY, not directly to SwiftTerm.
            // Intercept and route as `.shiftEnter` so tmux delivers the
            // proper extended-key sequence to the pane.
            let returnChars: Set = ["\r", "\u{3}"]
            if let chars = event.charactersIgnoringModifiers, returnChars.contains(chars) {
                let activeModifiers = event.modifierFlags
                    .intersection([.shift, .control, .option, .command])
                if activeModifiers == .shift {
                    onInput?([.shiftEnter])
                    return
                }
            }

            terminalView.keyDown(with: event)
        }

        // MARK: - URL Detection

        /// Bridges SwiftTerm's `Terminal` to the closures expected by `TerminalURLDetector`.
        /// Uses cached payloads (extracted before clearing) instead of live cell payloads.
        /// Converts viewport rows to absolute buffer rows for cache lookup.
        private func urlClosures(for terminal: Terminal) -> (
            lineText: (Int) -> String?,
            cellPayload: (Int, Int) -> String?
        ) {
            let cache = payloadCache
            let yDisp = terminal.buffer.yDisp
            return (
                lineText: { terminal.getLine(row: $0)?.translateToString(trimRight: true) },
                cellPayload: { col, row in cache.cellPayload(col: col, absoluteRow: row + yDisp) }
            )
        }

        private func extractAndClearPayloads() {
            payloadCache.extractAndClear(from: terminalView.getTerminal())
        }

        /// Converts a point in this view's coordinate space to a viewport grid position (col, row).
        /// The returned row is a viewport row suitable for `Terminal.getLine(row:)`.
        private func gridPosition(for point: NSPoint) -> (col: Int, row: Int)? {
            guard cellSize.width > 0, cellSize.height > 0 else { return nil }

            // Translate the click into terminalView's own bottom-left coordinate
            // space. When dimensions are locked (tmux pane), terminalView is
            // pinned to the top of the InteractiveTerminalView with
            // `frame.origin.y = bounds.height - frame.height`, so accounting
            // for the offset is required — otherwise clicks near the visual top
            // map below row 0 and get clamped, hiding the real row.
            let terminalLocalY = point.y - terminalView.frame.origin.y
            let terminalPoint = NSPoint(
                x: point.x + horizontalOffset,
                y: terminalLocalY
            )

            let terminal = terminalView.getTerminal()

            // SwiftTerm rows count down from the visual top; AppKit's local y
            // counts up from the bottom, so subtract from frame.height.
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
        private func updateCursor(for event: NSEvent) {
            if isMouseModeActive {
                NSCursor.arrow.set()
            } else if isOverURL {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }

        /// Called by the scroll overlay on click — opens URL if one is at the click position.
        ///
        /// In normal mode `allowedSchemes` is the union of the default
        /// http/https/ftp set plus `file://`, so OSC 8 file links from the
        /// local terminal are routed through `onOpenURL` and open as an
        /// in-app file tab. In mouse mode the caller passes `["file"]` so
        /// only file links are intercepted; all other URLs fall through to
        /// the terminal app.
        ///
        /// `TerminalURLDetector` still rejects `file://` by default for the
        /// hover/highlight rendering path (which can run against remote panes
        /// where opening local files would be unsafe).
        fileprivate func handleURLClick(at point: NSPoint, allowedSchemes: Set<String>) -> Bool {
            guard let pos = gridPosition(for: point) else { return false }
            let terminal = terminalView.getTerminal()
            let closures = urlClosures(for: terminal)
            if
                let url = TerminalURLDetector.urlAt(
                    col: pos.col,
                    row: pos.row,
                    cols: terminal.cols,
                    lineText: closures.lineText,
                    cellPayload: closures.cellPayload,
                    allowedSchemes: allowedSchemes
                ),
                let nsURL = URL(string: url) {
                openURL(nsURL)
                return true
            }
            return false
        }

        /// Whether the given point lies on a URL we want to intercept (any of
        /// `allowedSchemes`). Used to suppress the mouse-mode press so terminal
        /// apps (e.g. Claude Code) don't act on the click before our
        /// `handleURLClick` runs in `mouseUp` — e.g. opening the URL in the
        /// system default browser via `open(1)`, which would race past the
        /// `browserLinkBehavior` prompt.
        fileprivate func isClickOnInterceptableURL(
            at point: NSPoint,
            allowedSchemes: Set<String>
        ) -> Bool {
            guard let pos = gridPosition(for: point) else { return false }
            let terminal = terminalView.getTerminal()
            let closures = urlClosures(for: terminal)
            return TerminalURLDetector.urlAt(
                col: pos.col,
                row: pos.row,
                cols: terminal.cols,
                lineText: closures.lineText,
                cellPayload: closures.cellPayload,
                allowedSchemes: allowedSchemes
            ) != nil
        }

        /// Opens a URL by giving `onOpenURL` first chance to handle it. Falls
        /// back to the `URLOpener` dependency (`NSWorkspace.shared.open` in
        /// production, a file-backed log in E2E tests) when the callback is
        /// absent or declines to handle the URL.
        private func openURL(_ url: URL) {
            if onOpenURL?(url) == true { return }
            @Dependency(URLOpener.self) var urlOpener
            urlOpener.openInDefaultBrowser(url)
        }

        // MARK: - URL Underlines

        /// Scans visible rows for URLs and draws persistent underline decorations.
        /// Called when terminal content changes or scrolls.
        ///
        /// When mouse mode is active the underlines are cleared and redrawing
        /// is skipped: the terminal app owns the click stream for non-file
        /// URLs, so links shouldn't appear interactive. `file://` links are
        /// still interceptable (see `mouseUp`/`handleURLClick`), but we
        /// intentionally don't underline them either — keeping the visual
        /// behavior uniform across schemes while mouse mode is on.
        ///
        /// Note: this wrapper view doesn't subclass `TerminalView`, so it has no
        /// `mouseModeChanged` override. Existing underlines are cleared on the
        /// next layout pass (`rangeChanged`/`scrolled`), unlike iOS which
        /// repaints immediately. In practice TUIs always redraw when toggling
        /// mouse tracking, so the latency isn't user-visible.
        private func updateURLUnderlines() {
            for layer in urlUnderlineLayers {
                layer.removeFromSuperlayer()
            }
            urlUnderlineLayers.removeAll()

            if isMouseModeActive { return }

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

        // MARK: - Right Edge Background Fill

        /// Recomputes the trailing-cell background fill for the reserved-scroller
        /// margin on the right. Mirrors `updateURLUnderlines`' lifecycle — driven
        /// from `layout()` whenever terminal content changes or scrolls.
        ///
        /// For each displayed row it extends that row's last cell's background
        /// into the margin, so full-pane-width bands (Codex's filled panels)
        /// reach the view's right edge instead of stopping at the last cell.
        /// `getLine(row:)` is scroll-aware (`row + buffer.yDisp`), so the fill
        /// tracks scrollback the same way the cell rendering does.
        private func updateRightEdgeBackground() {
            guard let fillView = rightEdgeFillView else { return }

            let cs = cellSize
            let terminal = terminalView.getTerminal()
            let cols = terminal.cols
            guard cs.width > 0, cs.height > 0, cols > 0 else {
                fillView.setFills([])
                return
            }

            // Right edge of the drawn cells, in this view's coordinate space.
            let cellsRight = CGFloat(cols) * cs.width - horizontalOffset
            let marginWidth = bounds.width - cellsRight
            // Nothing to paint when the cells already reach (or overflow) the edge.
            guard marginWidth > 0 else {
                fillView.setFills([])
                return
            }

            let defaultBg = terminalView.nativeBackgroundColor
            let colorMapper = TerminalColorMapper(
                defaultFg: terminalView.nativeForegroundColor,
                defaultBg: defaultBg
            )

            var fills: [(rect: CGRect, color: CGColor)] = []
            fills.reserveCapacity(terminal.rows)
            for row in 0..<terminal.rows {
                guard let line = terminal.getLine(row: row) else { continue }
                let attr = line[cols - 1].attribute
                let style = attr.style
                // Trailing-cell background, honoring reverse video — matches the
                // bg resolution in `buildAttributes`.
                let bg: NSColor = style.contains(.inverse)
                    ? colorMapper.mapColor(attr.fg, isFg: true, isBold: style.contains(.bold))
                    : colorMapper.mapColor(attr.bg, isFg: false, isBold: false)
                let y = CGFloat(row) * cs.height
                fills.append((
                    rect: CGRect(x: cellsRight, y: y, width: marginWidth, height: cs.height),
                    color: bg.cgColor
                ))
            }
            fillView.setFills(fills)
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
            updateRightEdgeBackground()
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
            guard let url = URL(string: link) else { return }
            // In mouse mode the matching mouseDown/mouseUp carve-out already
            // suppresses + intercepts the click before SwiftTerm gets a chance
            // to fire this delegate, so reaching here in mouse mode means a
            // non-mouse hyperlink activation (e.g. keyboard) — open through
            // the same path as normal mode.
            openURL(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let string = String(data: content, encoding: .utf8) {
                let trimmed = InteractiveTerminalView.trimTrailingWhitespacePerLine(string)
                @Dependency(ClipboardClient.self) var clipboard
                clipboard.setString(trimmed)
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
