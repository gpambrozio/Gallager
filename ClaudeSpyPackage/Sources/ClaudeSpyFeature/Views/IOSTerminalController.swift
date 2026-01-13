#if os(iOS)
    import ClaudeSpyCommon
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Controller that manages a SwiftTerm TerminalView for iOS with fixed dimensions.
    ///
    /// Similar to the macOS TerminalController but uses UIKit instead of AppKit.
    /// Wraps the TerminalView in a UIScrollView to provide both horizontal and vertical scrolling.
    @Observable
    @MainActor
    final class IOSTerminalController: @unchecked Sendable {
        /// The scroll view containing the terminal
        let scrollView: UIScrollView

        /// The underlying SwiftTerm terminal view
        let terminalView: TerminalView

        /// Font name for the terminal
        var fontName = "SF Mono" {
            didSet { updateFont() }
        }

        /// Font size for the terminal
        var fontSize: CGFloat = 12 {
            didSet { updateFont() }
        }

        /// Number of columns (fixed to pane size)
        private(set) var columns = 80

        /// Number of rows (fixed to pane size)
        private(set) var rows = 24

        /// The fixed size of the terminal content
        private var terminalSize = CGSize(width: 800, height: 600)

        /// Whether the user has scrolled away from the bottom
        private(set) var isScrolledUp = false

        init() {
            // Create terminal view with initial frame
            self.terminalView = TerminalView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )

            // Create scroll view to contain the terminal
            self.scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

            setupTerminal()
            setupScrollView()
        }

        private func setupTerminal() {
            // Configure terminal appearance
            updateFont()

            // Set up terminal colors (dark theme by default)
            applyDarkTheme()

            // Disable TerminalView's own scrolling since we wrap it in our own UIScrollView
            terminalView.isScrollEnabled = false
            terminalView.contentOffset = .zero

            // Hide input assistant items (keyboard suggestions bar)
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []
        }

        private func setupScrollView() {
            scrollView.backgroundColor = .black
            scrollView.addSubview(terminalView)
            scrollView.contentSize = terminalSize
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false
        }

        /// Feeds raw data (including ANSI escape sequences) to the terminal
        func feed(_ data: Data) {
            let bytes = [UInt8](data)
            terminalView.feed(byteArray: bytes[...])
        }

        /// Feeds a string to the terminal
        func feed(_ string: String) {
            if let data = string.data(using: .utf8) {
                feed(data)
            }
        }

        /// Clears the terminal display
        func clear() {
            // Send clear screen escape sequence
            feed("\u{1b}[2J\u{1b}[H")
        }

        /// Resizes the terminal to the specified dimensions and calculates the fixed pixel size
        func resize(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows

            // Resize the terminal's internal buffer
            terminalView.getTerminal().resize(cols: columns, rows: rows)

            // Calculate the pixel size needed for this terminal
            updateTerminalFrameSize()
        }

        /// Updates the terminal frame size based on current font and dimensions
        private func updateTerminalFrameSize() {
            // Calculate cell size from font metrics (matches SwiftTerm's computeFontDimensions)
            let cellSize = calculateCellSize()

            // Calculate required size
            let width = CGFloat(columns) * cellSize.width
            let height = CGFloat(rows) * cellSize.height

            terminalSize = CGSize(width: width, height: height)

            // Update the terminal view frame
            terminalView.frame = CGRect(origin: .zero, size: terminalSize)

            // Update scroll view content size
            scrollView.contentSize = terminalSize
        }

        /// Calculates the cell size based on the current font
        private func calculateCellSize() -> CGSize {
            FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
        }

        /// Scrolls to the bottom of the terminal
        func scrollToBottom() {
            let maxY = max(0, terminalSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: maxY), animated: true)
            isScrolledUp = false
        }

        /// Gets the terminal's scrollback content as data
        func getScrollbackContent() -> Data {
            terminalView.getTerminal().getBufferAsData()
        }

        // MARK: - Theme Support

        func applyDarkTheme() {
            let bgColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeForegroundColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = bgColor
            scrollView.backgroundColor = bgColor
        }

        func applyLightTheme() {
            let bgColor = UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
            terminalView.nativeForegroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeBackgroundColor = bgColor
            scrollView.backgroundColor = bgColor
        }

        // MARK: - Private Helpers

        private func updateFont() {
            let font = UIFont(name: fontName, size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            terminalView.font = font

            // Recalculate terminal size with new font
            updateTerminalFrameSize()
        }
    }

    /// A SwiftUI wrapper around IOSTerminalController's scroll view
    struct IOSTerminalContainerView: UIViewRepresentable {
        /// The terminal controller that manages the underlying terminal
        let terminalController: IOSTerminalController

        func makeUIView(context: Context) -> UIScrollView {
            terminalController.scrollView
        }

        func updateUIView(_ uiView: UIScrollView, context: Context) {
            // Updates are handled by the IOSTerminalController
        }
    }
#endif
