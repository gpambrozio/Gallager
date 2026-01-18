#if os(iOS)
    import ClaudeSpyNetworking
    import SwiftTerm
    import UIKit

    /// A terminal view that accepts keyboard input and forwards it via a callback.
    ///
    /// Features:
    /// - `canBecomeFirstResponder` controlled by `inputEnabled` property
    /// - Implements `TerminalViewDelegate` to capture typed characters
    /// - Converts raw bytes to `TmuxKey` representations for relay transmission
    /// - Preserves scroll position when new content arrives
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

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            terminalDelegate = self
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
            // Could open links in Safari if desired
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            // Could provide haptic feedback
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
