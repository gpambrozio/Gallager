#if os(iOS)
    import ClaudeSpyNetworking
    import SwiftTerm
    import UIKit

    // MARK: - Terminal URL Detection

    /// Detects plain-text URLs in terminal buffer text at a given grid position.
    private enum TerminalURLDetector {
        /// URL pattern matching common schemes.
        /// Matches http://, https://, ftp://, and file:// URLs.
        private static let urlPattern: String = {
            let schemes = "https?://|ftp://|file://"
            let urlChars = "[^\\s<>\"'`\\]\\)\\}\\|]"
            return "(?:\(schemes))\(urlChars)+"
        }()

        private static let urlRegex: NSRegularExpression? = {
            try? NSRegularExpression(pattern: urlPattern, options: [])
        }()

        /// Represents a detected URL with its column range within a terminal line.
        struct DetectedURL {
            let url: String
            let startCol: Int
            let endCol: Int
        }

        /// Extracts text from a terminal line and finds all URLs in it.
        static func detectURLs(in terminal: Terminal, row: Int) -> [DetectedURL] {
            guard let line = terminal.getLine(row: row) else { return [] }
            let text = line.translateToString(trimRight: true)
            guard !text.isEmpty else { return [] }

            guard let regex = urlRegex else { return [] }
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

            return matches.compactMap { match in
                let urlString = nsText.substring(with: match.range)
                let cleaned = cleanTrailingPunctuation(urlString)
                guard URL(string: cleaned) != nil else { return nil }

                let startCol = match.range.location
                let endCol = startCol + cleaned.count
                return DetectedURL(url: cleaned, startCol: startCol, endCol: endCol)
            }
        }

        /// Finds the URL at a specific column position in a terminal row.
        static func urlAt(col: Int, row: Int, in terminal: Terminal) -> String? {
            let urls = detectURLs(in: terminal, row: row)
            return urls.first(where: { col >= $0.startCol && col < $0.endCol })?.url
        }

        /// Removes trailing punctuation that commonly follows URLs in text but isn't part of the URL.
        private static func cleanTrailingPunctuation(_ url: String) -> String {
            var result = url
            let trailingChars: Set<Character> = [".", ",", ";", ":", "!", "?"]
            while let last = result.last, trailingChars.contains(last) {
                result.removeLast()
            }
            if result.hasSuffix(")"), !result.contains("(") {
                result.removeLast()
            }
            return result
        }
    }

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
            longPress.delegate = self
            addGestureRecognizer(longPress)
        }

        /// Computes the cell size matching SwiftTerm's internal calculations.
        private func computeCellSize() -> CGSize {
            let ctFont = font as CTFont
            let lineAscent = CTFontGetAscent(ctFont)
            let lineDescent = CTFontGetDescent(ctFont)
            let lineLeading = CTFontGetLeading(ctFont)
            let cellHeight = ceil(lineAscent + lineDescent + lineLeading)
            let fontAttributes: [NSAttributedString.Key: Any] = [.font: font]
            let cellWidth = "W".size(withAttributes: fontAttributes).width
            return CGSize(width: max(1, cellWidth), height: max(1, cellHeight))
        }

        /// Converts a content-space point to a viewport grid position (col, viewportRow).
        /// The viewportRow is suitable for use with `Terminal.getLine(row:)`.
        private func gridPosition(for point: CGPoint) -> (col: Int, row: Int)? {
            let cellSize = computeCellSize()
            guard cellSize.width > 0, cellSize.height > 0 else { return nil }

            let terminal = getTerminal()

            // gesture.location(in: self) returns content coordinates in a UIScrollView.
            // Subtract contentOffset to get position within the visible viewport.
            let visibleX = point.x
            let visibleY = point.y - contentOffset.y

            let col = Int(visibleX / cellSize.width)
            let row = Int(visibleY / cellSize.height)

            let clampedCol = min(max(0, col), terminal.cols - 1)
            let clampedRow = min(max(0, row), terminal.rows - 1)

            return (clampedCol, clampedRow)
        }

        @objc
        private func handleURLLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                let point = gesture.location(in: self)
                guard let pos = gridPosition(for: point) else { return }

                let terminal = getTerminal()
                guard let url = TerminalURLDetector.urlAt(col: pos.col, row: pos.row, in: terminal) else {
                    return
                }

                // Show highlight
                let urls = TerminalURLDetector.detectURLs(in: terminal, row: pos.row)
                if let detected = urls.first(where: { pos.col >= $0.startCol && pos.col < $0.endCol }) {
                    showURLHighlight(row: pos.row, startCol: detected.startCol, endCol: detected.endCol)
                }

                // Show action sheet to open URL
                showURLActionSheet(url: url)

            case .ended, .cancelled, .failed:
                removeURLHighlight()

            default:
                break
            }
        }

        private func showURLHighlight(row: Int, startCol: Int, endCol: Int) {
            let cellSize = computeCellSize()

            // row is a viewport row. Convert to content coordinates for positioning.
            let x = CGFloat(startCol) * cellSize.width
            let y = CGFloat(row) * cellSize.height + contentOffset.y
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
    }

    // MARK: - UIGestureRecognizerDelegate

    extension InteractiveTerminalView: UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Allow long-press to work alongside scroll gestures
            true
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
            // No-op
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // No-op - iTerm2 specific sequences not needed
        }
    }
#endif
