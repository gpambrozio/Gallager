#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
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

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            terminalDelegate = self
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

            blockScrollChanges = false
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateURLUnderlines()
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

        /// Converts a content-space point to a grid position (col, row) suitable for `Terminal.getLine(row:)`.
        ///
        /// Computes the absolute buffer row from content-space coordinates, then derives
        /// the viewport row via `buffer.yDisp`. This avoids drift between `contentOffset`
        /// and `yDisp` that occurs when the user scrolls the UIScrollView.
        private func gridPosition(for point: CGPoint) -> (col: Int, row: Int)? {
            let cellSize = FontMetrics.calculateCellSize(font: font as CTFont)
            guard cellSize.width > 0, cellSize.height > 0 else { return nil }

            let terminal = getTerminal()

            let col = Int(point.x / cellSize.width)
            // Absolute buffer row from content-space y, then convert to viewport row.
            // getLine(row:) adds yDisp back, so: lines[row + yDisp] = lines[absoluteRow] ✓
            let absoluteRow = Int(point.y / cellSize.height)
            let row = absoluteRow - terminal.buffer.yDisp

            guard row >= 0, row < terminal.rows else { return nil }
            let clampedCol = min(max(0, col), terminal.cols - 1)

            return (clampedCol, row)
        }

        @objc
        private func handleURLTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            guard let pos = gridPosition(for: point) else { return }

            let terminal = getTerminal()
            let lineText: (Int) -> String? = { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            if
                let url = TerminalURLDetector.urlAt(col: pos.col, row: pos.row, lineText: lineText),
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
                let urls = TerminalURLDetector.detectURLs(row: pos.row) {
                    terminal.getLine(row: $0)?.translateToString(trimRight: true)
                }
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

            // row is a viewport row. Use yDisp for absolute content-space positioning.
            let x = CGFloat(startCol) * cellSize.width
            let absoluteRow = row + getTerminal().buffer.yDisp
            let y = CGFloat(absoluteRow) * cellSize.height
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
                UIPasteboard.general.string = url
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

            for row in 0..<terminal.rows {
                let urls = TerminalURLDetector.detectURLs(row: row) {
                    terminal.getLine(row: $0)?.translateToString(trimRight: true)
                }
                for url in urls {
                    let x = CGFloat(url.startCol) * cellSize.width
                    // Absolute content-space y using buffer offset, so underlines scroll with text
                    let absoluteRow = row + yDisp
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
                UIPasteboard.general.string = string
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
