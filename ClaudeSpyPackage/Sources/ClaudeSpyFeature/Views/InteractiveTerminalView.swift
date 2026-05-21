#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Dependencies
    import SwiftTerm
    import UIKit

    // MARK: - Interactive Terminal View

    /// A terminal view that accepts keyboard input and forwards it via a callback.
    ///
    /// Features:
    /// - `canBecomeFirstResponder` controlled by `inputEnabled` property
    /// - Implements `TerminalViewDelegate` to capture typed characters
    /// - Converts raw bytes to `TmuxKey` representations for relay transmission
    /// - Preserves scroll position when new content arrives
    /// - Long-press on URLs opens them in Safari
    ///
    /// Usage:
    /// ```swift
    /// let terminal = InteractiveTerminalView(frame: .zero, font: font)
    /// terminal.onInput = { keys in
    ///     await relayClient.sendCommand(SendKeystroke(keys), paneId: paneId)
    /// }
    /// ```
    final class InteractiveTerminalView: TerminalView {
        /// Callback invoked when the user types. The keys are ready for relay transmission.
        /// Marked @MainActor for Swift 6 strict concurrency safety.
        var onInput: (@MainActor ([TmuxKey]) -> Void)?

        /// Callback invoked for raw escape sequences (e.g., SGR mouse events) that must be
        /// sent to tmux as-is, bypassing TmuxKey conversion.
        var onRawInput: (@MainActor (Data) -> Void)?

        /// Callback invoked when the terminal title changes (via OSC 0 or OSC 2 escape sequences).
        var onTitleChange: (@MainActor (String) -> Void)?

        /// Set to true after initial content has been loaded to enable scroll preservation
        var preserveUserScroll = false

        /// Controls whether the terminal can accept keyboard input.
        /// When false, tapping the terminal won't show the keyboard.
        /// Use `activateInput()` and `deactivateInput()` to control this.
        var inputEnabled = false

        /// When true, blocks all contentOffset changes to preserve scroll position
        private var blockScrollChanges = false

        /// Pan gesture used to synthesize SGR mouse scroll events when the host has
        /// tmux mouse mode enabled. Only begins when `isMouseModeActive` is true.
        private var mouseModePanGesture: UIPanGestureRecognizer?

        /// Outer scroll view's pan gesture (from `TerminalStreamContainerView`).
        /// Stored so we can require it to fail to ours when mouse mode is active —
        /// otherwise tall-terminal vertical scrolling would steal the drag.
        private weak var outerScrollPanGesture: UIPanGestureRecognizer?

        /// Accumulated translation since the last emitted scroll event. Pan gestures
        /// deliver translations at refresh rate; we accumulate and emit one SGR
        /// event per cell-height crossed so the rate matches what the user sees.
        private var mouseModeAccumulatedY: CGFloat = 0

        /// Highlight layer shown over detected URL during long-press
        private var urlHighlightLayer: CALayer?
        private var urlUnderlineLayers: [CALayer] = []

        /// Cell size cached on first access to avoid recomputing CoreText
        /// measurements on every pan-gesture callback (60–120 Hz). The font
        /// is fixed at `init` so no invalidation is currently wired up; if a
        /// runtime font change is ever added, clear this from the setter.
        private var cachedCellSize: CGSize?

        /// OSC 8 hyperlink payload cache, mirrored from SwiftTerm cells before
        /// we clear them to suppress SwiftTerm's own dashed underline rendering.
        /// See `TerminalPayloadCache` for the full rationale.
        private let payloadCache = TerminalPayloadCache()

        /// Set to `true` once `init` has fully run. SwiftTerm's `Terminal.init`
        /// fires `mouseMode.didSet` from inside its setup, which calls our
        /// `mouseModeChanged` override before `TerminalView.terminal` has been
        /// assigned — calling `getTerminal()` then trips a precondition.
        /// We use this flag to skip the synchronous underline refresh until
        /// init has finished. There can't be stale underlines during init.
        private var didFinishInit = false

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            terminalDelegate = self
            // Always render cursor as filled on iOS since the user is typically viewing
            // the remote terminal, not typing. The hollow/filled distinction is less useful
            // here — cursor visibility (DECTCEM ?25l/?25h) handles show/hide instead.
            caretViewTracksFocus = false
            setupURLLongPress()
            setupMouseModePan()
            self.didFinishInit = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var canBecomeFirstResponder: Bool {
            inputEnabled
        }

        /// Block contentOffset changes while preserving scroll position
        override var contentOffset: CGPoint {
            get { super.contentOffset }
            set {
                if blockScrollChanges {
                    return
                }
                super.contentOffset = newValue
            }
        }

        /// Feeds data while preserving scroll position if user has scrolled up.
        func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
            if preserveUserScroll {
                let maxScrollY = max(0, contentSize.height - bounds.height)
                let isAtBottom = maxScrollY <= 0 || super.contentOffset.y >= maxScrollY - 5
                blockScrollChanges = !isAtBottom
            }

            feed(byteArray: bytes)
            extractAndClearPayloads()

            blockScrollChanges = false
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateURLUnderlines()
        }

        /// Returns the cached cell size, recalculating only on first access or after invalidation.
        /// Used by hot paths (pan/scroll callbacks) where `FontMetrics.calculateCellSize`'s
        /// CoreText measurements would otherwise run at refresh rate.
        private var cellSize: CGSize {
            if let cached = cachedCellSize { return cached }
            let size = FontMetrics.calculateCellSize(font: font as CTFont)
            cachedCellSize = size
            return size
        }

        /// Scrolls the inner terminal (SwiftTerm's scrollback) to the bottom.
        func scrollToBottom() {
            let maxY = max(0, contentSize.height - bounds.height)
            super.contentOffset = CGPoint(x: 0, y: maxY)
        }

        // MARK: - Focus Management

        /// Call to enable input and show the keyboard
        func activateInput() {
            inputEnabled = true
            _ = becomeFirstResponder()
        }

        /// Call to hide the keyboard and disable input
        func deactivateInput() {
            _ = resignFirstResponder()
            inputEnabled = false
        }

        // MARK: - URL Detection

        /// Bridges SwiftTerm's `Terminal` to the closures expected by `TerminalURLDetector`.
        /// Uses cached payloads (extracted before clearing) instead of live cell payloads.
        /// Accepts absolute buffer rows (from `gridPosition`) and uses `getScrollInvariantLine`
        /// so both viewport and scrollback rows work.
        private func urlClosures(for terminal: Terminal) -> (
            lineText: (Int) -> String?,
            cellPayload: (Int, Int) -> String?
        ) {
            let cache = payloadCache
            return (
                lineText: { terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) },
                cellPayload: { col, row in cache.cellPayload(col: col, absoluteRow: row) }
            )
        }

        private func extractAndClearPayloads() {
            payloadCache.extractAndClear(from: getTerminal())
        }

        private func setupURLLongPress() {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleURLLongPress))
            longPress.minimumPressDuration = 0.5
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            addGestureRecognizer(longPress)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleURLTap))
            tap.cancelsTouchesInView = false
            tap.require(toFail: longPress)
            tap.delegate = self
            addGestureRecognizer(tap)
        }

        // MARK: - Mouse Mode Scrolling

        /// True when the host terminal currently has tmux mouse mode enabled.
        /// Mirrors the macOS check so SGR escape sequences only synthesize
        /// when the remote app is actually listening for them.
        var isMouseModeActive: Bool {
            getTerminal().mouseMode != .off
        }

        /// Adds a single-finger pan gesture that synthesizes SGR scroll wheel
        /// events when mouse mode is active. The gesture's delegate gates
        /// `shouldBegin` on `isMouseModeActive` so normal scrolling is preserved
        /// when the host isn't in mouse mode.
        private func setupMouseModePan() {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMouseModePan))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delegate = self
            // Block SwiftTerm's own scrollback pan when ours engages — they share
            // the same view so without this both fire and the buffer scrolls
            // visually while we're sending mouse events.
            panGestureRecognizer.require(toFail: pan)
            addGestureRecognizer(pan)
            mouseModePanGesture = pan
        }

        /// Called by the container view to register the outer scroll view's pan
        /// gesture. We make it require ours to fail so a vertical drag in mouse
        /// mode doesn't get hijacked by tall-terminal scrolling.
        func attachOuterScrollPanGesture(_ pan: UIPanGestureRecognizer) {
            outerScrollPanGesture = pan
            if let mouseModePanGesture {
                pan.require(toFail: mouseModePanGesture)
            }
        }

        /// Intercepts Shift+Return before SwiftTerm collapses the modifier.
        /// SwiftTerm's legacy presses path emits plain `\r` for both Enter and
        /// Shift+Enter unless the inner app has pushed kitty mode — which it
        /// can't here, since it talks to tmux's PTY rather than directly to
        /// SwiftTerm. A `UIKeyCommand` matches before `pressesBegan` runs, so
        /// SwiftTerm never sees the event. Routing as `.shiftEnter` lets the
        /// macOS host translate it to `tmux send-keys S-Enter`, delivering the
        /// proper extended-key sequence to the pane.
        ///
        /// `pressesBegan` is `public` (not `open`) on SwiftTerm's TerminalView
        /// so direct override from another module is blocked; `keyCommands` is
        /// `open` on UIResponder and is the supported extension point.
        override var keyCommands: [UIKeyCommand]? {
            var commands = super.keyCommands ?? []
            let shiftReturn = UIKeyCommand(
                input: "\r",
                modifierFlags: .shift,
                action: #selector(handleShiftReturn(_:))
            )
            shiftReturn.wantsPriorityOverSystemBehavior = true
            commands.append(shiftReturn)
            return commands
        }

        @objc
        private func handleShiftReturn(_: UIKeyCommand) {
            onInput?([.shiftEnter])
        }

        /// Gates the mouse-mode pan on `isMouseModeActive` so normal scrolling
        /// still works when the host doesn't have tmux mouse mode enabled.
        ///
        /// Implemented as an `override` rather than via `UIGestureRecognizerDelegate`
        /// because `UIScrollView` already implements this method and Swift forbids
        /// extension overrides.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === mouseModePanGesture {
                guard isMouseModeActive, let mouseModePanGesture else { return false }
                // Only consume vertical pans as wheel events — horizontal pans
                // need to reach the outer scroll view for native horizontal
                // scrolling of wide terminal content. Tie / no-movement defaults
                // to vertical so straight-down drags trigger wheel events.
                //
                // Translation captures how far the finger has moved (slow
                // steady drag); velocity captures a fast flick that's barely
                // moved yet. Mixing the two terms isn't dimensionally clean,
                // but the comparison is symmetric across axes so it correctly
                // classifies both gesture styles.
                let translation = mouseModePanGesture.translation(in: self)
                let velocity = mouseModePanGesture.velocity(in: self)
                let dx = abs(translation.x) + abs(velocity.x)
                let dy = abs(translation.y) + abs(velocity.y)
                return dy >= dx
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        /// Overrides SwiftTerm's mouse-mode handler to neutralize the pan gestures
        /// it adds when mouse mode activates (`panMouseGesture`, eventually
        /// `panSelectionGesture`).
        ///
        /// Two adjustments per added pan:
        /// 1. `require(toFail: mouseModePanGesture)` so SwiftTerm's
        ///    `sharedMouseEvent` handler doesn't fire alongside our scroll-wheel
        ///    sequences (would double up events on every drag).
        /// 2. `pan.delegate = self` so our `gestureRecognizerShouldBegin` is
        ///    consulted — letting us decline horizontal pans, which the remote
        ///    terminal can't act on, so they fall through to the outer scroll
        ///    view for native horizontal scrolling of wide terminal content.
        @MainActor
        override func mouseModeChanged(source: Terminal) {
            super.mouseModeChanged(source: source)
            let active = source.mouseMode != .off
            // Disable inner UIScrollView's gesture pan in mouse mode — its
            // contentSize matches bounds horizontally so it can't scroll
            // horizontally, but the recognizer still claims horizontal touches
            // and blocks the outer scroll view from receiving them.
            isScrollEnabled = !active
            // Disable any pan gestures SwiftTerm added via super's
            // `enableMousePanGesture()` so they can't intercept any direction —
            // our `mouseModePanGesture` already produces SGR scroll-wheel events
            // for vertical pans, and horizontal pans should reach the outer
            // scroll view for native scrolling of wide terminal content.
            for gesture in gestureRecognizers ?? [] {
                guard
                    let pan = gesture as? UIPanGestureRecognizer,
                    pan !== mouseModePanGesture,
                    pan !== panGestureRecognizer
                else { continue }
                pan.isEnabled = !active
            }
            // Re-run underline rendering immediately: enabling mouse mode
            // hides them, disabling it brings them back. Calling directly
            // rather than relying on `setNeedsLayout()` ensures stale
            // underlines disappear in the same frame as the mode change,
            // not on the next layout pass.
            //
            // Skip during init: SwiftTerm's `Terminal.init` fires this via
            // `mouseMode.didSet` before `TerminalView.terminal` is assigned,
            // so `getTerminal()` inside `updateURLUnderlines()` would crash.
            // No underlines exist yet at that point — nothing to clear.
            guard didFinishInit else { return }
            updateURLUnderlines()
        }

        @objc
        private func handleMouseModePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                mouseModeAccumulatedY = 0
            case .changed:
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                emitMouseModeScrollEvents(deltaY: translation.y, at: gesture.location(in: self))
            case .ended,
                 .cancelled,
                 .failed:
                mouseModeAccumulatedY = 0
            default:
                break
            }
        }

        /// Translates accumulated pan movement into batched SGR scroll wheel
        /// sequences and forwards them via `onRawInput`.
        ///
        /// Touch deltas are in points; one cell-height of pixel scroll becomes
        /// one line event so the rate matches what the user sees visually
        /// (mirrors the macOS trackpad path in `ScrollEventOverlay.scrollWheel`).
        ///
        /// "Drag finger down" (translation.y > 0) reveals older content above —
        /// that's a scroll-up event (button 64). "Drag finger up" sends scroll
        /// down (button 65). This matches natural-scrolling expectations.
        private func emitMouseModeScrollEvents(deltaY: CGFloat, at location: CGPoint) {
            guard deltaY != 0 else { return }

            // Reset accumulator on direction change for responsive reversal.
            if (mouseModeAccumulatedY > 0) != (deltaY > 0) {
                mouseModeAccumulatedY = 0
            }
            mouseModeAccumulatedY += deltaY

            let lineThreshold = max(cellSize.height, 1)
            var lines = 0
            while abs(mouseModeAccumulatedY) >= lineThreshold {
                lines += 1
                mouseModeAccumulatedY -= mouseModeAccumulatedY > 0 ? lineThreshold : -lineThreshold
            }
            guard lines > 0 else { return }

            let terminal = getTerminal()
            let cols = terminal.cols
            let rows = terminal.rows
            guard cellSize.width > 0, cellSize.height > 0, cols > 0, rows > 0 else { return }

            let col = min(max(0, Int(location.x / cellSize.width)), cols - 1)
            let visibleY = location.y - contentOffset.y
            let row = min(max(0, Int(visibleY / cellSize.height)), rows - 1)

            // Button 64 = scroll up (older content), 65 = scroll down (newer).
            // Drag finger down (deltaY > 0) → reveal older content → scroll up.
            let button = deltaY > 0 ? 64 : 65
            // SGR format: ESC [ < Cb ; Cx ; Cy M  (1-indexed coordinates)
            let singleEvent = "\u{1b}[<\(button);\(col + 1);\(row + 1)M"
            let batch = String(repeating: singleEvent, count: lines)
            onRawInput?(Data(batch.utf8))
        }

        /// Converts a content-space point to a grid position (col, absoluteRow).
        ///
        /// Returns absolute buffer row indices suitable for `getScrollInvariantLine(row:)`,
        /// so both viewport and scrollback rows work for URL detection.
        private func gridPosition(for point: CGPoint) -> (col: Int, row: Int)? {
            guard cellSize.width > 0, cellSize.height > 0 else { return nil }

            let terminal = getTerminal()

            let col = Int(point.x / cellSize.width)
            let absoluteRow = Int(point.y / cellSize.height)

            // Verify the row is within the buffer
            guard terminal.getScrollInvariantLine(row: absoluteRow) != nil else { return nil }
            let clampedCol = min(max(0, col), terminal.cols - 1)

            return (clampedCol, absoluteRow)
        }

        @objc
        private func handleURLTap(_ gesture: UITapGestureRecognizer) {
            // Single tap opens URLs in Safari regardless of mouse mode. Underlines
            // are still suppressed in mouse mode (visual policy), but iOS doesn't
            // synthesize SGR mouse clicks on tap — only the pan gesture sends
            // mouse events — so opening the URL on tap doesn't compete with the
            // remote app's click semantics. Long-press still skips in mouse mode
            // because the action sheet is disruptive over an interactive TUI.

            let point = gesture.location(in: self)
            guard let pos = gridPosition(for: point) else { return }

            let terminal = getTerminal()
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
                UIApplication.shared.open(nsURL)
            }
        }

        @objc
        private func handleURLLongPress(_ gesture: UILongPressGestureRecognizer) {
            // In mouse mode the remote terminal app owns presses, so the
            // long-press action sheet shouldn't appear over interactive UI.
            guard !isMouseModeActive else { return }

            switch gesture.state {
            case .began:
                let point = gesture.location(in: self)
                guard let pos = gridPosition(for: point) else { return }

                let terminal = getTerminal()
                let closures = urlClosures(for: terminal)
                let urls = TerminalURLDetector.detectURLs(
                    row: pos.row,
                    cols: terminal.cols,
                    lineText: closures.lineText,
                    cellPayload: closures.cellPayload
                )
                guard let detected = urls.first(where: { pos.col >= $0.startCol && pos.col < $0.endCol }) else {
                    return
                }

                // Show highlight and action sheet
                showURLHighlight(row: pos.row, startCol: detected.startCol, endCol: detected.endCol)
                showURLActionSheet(url: detected.url)

            case .ended,
                 .cancelled,
                 .failed:
                removeURLHighlight()

            default:
                break
            }
        }

        private func showURLHighlight(row: Int, startCol: Int, endCol: Int) {
            // row is an absolute buffer row — use directly for content-space positioning.
            let x = CGFloat(startCol) * cellSize.width
            let y = CGFloat(row) * cellSize.height
            let width = CGFloat(endCol - startCol) * cellSize.width

            let highlightRect = CGRect(x: x, y: y, width: width, height: cellSize.height)

            if urlHighlightLayer == nil {
                let highlightLayer = CALayer()
                highlightLayer.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15).cgColor
                highlightLayer.borderColor = UIColor.tintColor.withAlphaComponent(0.3).cgColor
                highlightLayer.borderWidth = 1
                highlightLayer.cornerRadius = 2
                layer.addSublayer(highlightLayer)
                urlHighlightLayer = highlightLayer
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            urlHighlightLayer?.frame = highlightRect
            CATransaction.commit()
        }

        private func removeURLHighlight() {
            urlHighlightLayer?.removeFromSuperlayer()
            urlHighlightLayer = nil
        }

        private func showURLActionSheet(url: String) {
            guard let nsURL = URL(string: url) else { return }

            let alert = UIAlertController(
                title: "Open Link",
                message: url,
                preferredStyle: .actionSheet
            )

            alert.addAction(UIAlertAction(title: "Open in Safari", style: .default) { [weak self] _ in
                self?.removeURLHighlight()
                UIApplication.shared.open(nsURL)
            })

            alert.addAction(UIAlertAction(title: "Copy Link", style: .default) { [weak self] _ in
                self?.removeURLHighlight()
                @Dependency(ClipboardClient.self) var clipboard
                clipboard.setString(url)
            })

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.removeURLHighlight()
            })

            // Present from the nearest view controller
            if let viewController = findViewController() {
                // For iPad popover support
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = self
                    popover.sourceRect = urlHighlightLayer?.frame ?? bounds
                }
                viewController.present(alert, animated: true)
            }
        }

        private func findViewController() -> UIViewController? {
            var responder: UIResponder? = self
            while let nextResponder = responder?.next {
                if let viewController = nextResponder as? UIViewController {
                    return viewController
                }
                responder = nextResponder
            }
            return nil
        }

        // MARK: - URL Underlines

        /// Scans visible rows for URLs and draws persistent underline decorations.
        /// Positions use absolute content-space coordinates so underlines scroll with text.
        ///
        /// When mouse mode is active the underlines are cleared and redrawing
        /// is skipped: the remote terminal app owns taps, so links shouldn't
        /// appear interactive while their taps are consumed as mouse events.
        private func updateURLUnderlines() {
            for underline in urlUnderlineLayers {
                underline.removeFromSuperlayer()
            }
            urlUnderlineLayers.removeAll()

            if isMouseModeActive { return }

            let terminal = getTerminal()
            guard cellSize.width > 0, cellSize.height > 0 else { return }
            let yDisp = terminal.buffer.yDisp

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let closures = urlClosures(for: terminal)
            for viewportRow in 0..<terminal.rows {
                let absoluteRow = viewportRow + yDisp
                let urls = TerminalURLDetector.detectURLs(
                    row: absoluteRow,
                    cols: terminal.cols,
                    lineText: closures.lineText,
                    cellPayload: closures.cellPayload
                )
                for url in urls {
                    let x = CGFloat(url.startCol) * cellSize.width
                    let y = CGFloat(absoluteRow) * cellSize.height + cellSize.height - 2
                    let width = CGFloat(url.endCol - url.startCol) * cellSize.width

                    let underline = CALayer()
                    underline.backgroundColor = UIColor.tintColor.withAlphaComponent(0.6).cgColor
                    underline.frame = CGRect(x: x, y: y, width: width, height: 2)
                    layer.addSublayer(underline)
                    urlUnderlineLayers.append(underline)
                }
            }

            CATransaction.commit()
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    extension InteractiveTerminalView: UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Block simultaneous long-press recognition to prevent SwiftTerm's
            // long-press (0.7s) from triggering the system link preview popover
            // when our long-press (0.5s) already handled the URL.
            if
                gestureRecognizer is UILongPressGestureRecognizer,
                otherGestureRecognizer is UILongPressGestureRecognizer {
                return false
            }
            return true
        }
    }

    // MARK: - TerminalViewDelegate

    /// SwiftTerm's TerminalViewDelegate is not marked Sendable, but all delegate methods
    /// are called on the main thread from UIKit. We use @preconcurrency to bridge to
    /// Swift 6 strict concurrency while acknowledging this UIKit threading guarantee.
    extension InteractiveTerminalView: @preconcurrency TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Defense-in-depth: DA queries are stripped from the feed on the macOS host,
            // but catch any remaining auto-responses (cursor position reports, terminal
            // parameter reports) that SwiftTerm may still generate.
            if TerminalResponseFilter.isTerminalResponse(data) { return }

            // Convert raw bytes to TmuxKey representations
            let keys = TmuxKey.from(bytes: Data(data))
            guard !keys.isEmpty else { return }
            onInput?(keys)
        }

        func scrolled(source: TerminalView, position: Double) {
            // No-op - URL underlines scroll naturally with content via absolute positioning
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            onTitleChange?(title)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // No-op - size is managed externally
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // No-op
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // Defense-in-depth: ignore SwiftTerm's own link-open requests while
            // mouse mode is active. Our gesture handlers already short-circuit
            // on `isMouseModeActive`; this guard catches the implicit
            // regex-link path SwiftTerm exposes through this delegate.
            guard !isMouseModeActive else { return }
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let string = String(data: content, encoding: .utf8) {
                @Dependency(ClipboardClient.self) var clipboard
                clipboard.setString(string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            setNeedsLayout()
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // No-op - iTerm2 specific sequences not needed
        }
    }
#endif
