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

        /// Highlight layer shown over detected URL during long-press
        private var urlHighlightLayer: CALayer?
        private var urlUnderlineLayers: [CALayer] = []

        /// Cached OSC 8 payloads extracted from SwiftTerm cells before clearing.
        /// Structure: [absoluteBufferRow: [col: payloadString]]
        /// Keyed by absolute buffer row so lookups remain correct after scrolling.
        /// We clear SwiftTerm's cell payloads to prevent its own dashed underline rendering,
        /// but cache them here so our URL detection still works.
        private var cachedPayloads: [Int: [Int: String]] = [:]

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            terminalDelegate = self
            // Always render cursor as filled on iOS since the user is typically viewing
            // the remote terminal, not typing. The hollow/filled distinction is less useful
            // here — cursor visibility (DECTCEM ?25l/?25h) handles show/hide instead.
            caretViewTracksFocus = false
            setupURLLongPress()
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
            let payloads = cachedPayloads
            return (
                lineText: { terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) },
                cellPayload: { col, row in payloads[row]?[col] }
            )
        }

        /// Scans ALL terminal buffer lines for OSC 8 payloads, merges them into the cache, then clears them.
        /// We cache payloads so our URL detection works, but clear them from SwiftTerm's cells
        /// to prevent SwiftTerm from rendering its own dashed underlines.
        /// Merges rather than replaces so payloads from earlier feeds (already cleared) are preserved.
        private func extractAndClearPayloads() {
            let terminal = getTerminal()
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

        /// Converts a content-space point to a grid position (col, absoluteRow).
        ///
        /// Returns absolute buffer row indices suitable for `getScrollInvariantLine(row:)`,
        /// so both viewport and scrollback rows work for URL detection.
        private func gridPosition(for point: CGPoint) -> (col: Int, row: Int)? {
            let cellSize = FontMetrics.calculateCellSize(font: font as CTFont)
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
            let cellSize = FontMetrics.calculateCellSize(font: font as CTFont)

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
        private func updateURLUnderlines() {
            for underline in urlUnderlineLayers {
                underline.removeFromSuperlayer()
            }
            urlUnderlineLayers.removeAll()

            let terminal = getTerminal()
            let cellSize = FontMetrics.calculateCellSize(font: font as CTFont)
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

    // SwiftTerm's TerminalViewDelegate is not marked Sendable, but all delegate methods
    // are called on the main thread from UIKit. We use @preconcurrency to bridge to
    // Swift 6 strict concurrency while acknowledging this UIKit threading guarantee.
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
