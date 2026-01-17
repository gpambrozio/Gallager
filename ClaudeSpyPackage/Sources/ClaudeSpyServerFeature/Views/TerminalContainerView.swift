import AppKit
import ClaudeSpyCommon
import SwiftTerm
import SwiftUI

/// A flipped clip view that positions content at the top instead of bottom
final private class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A scroll view that notifies when its frame changes
final class ResizingScrollView: NSScrollView {
    var onResize: ((NSSize) -> Void)?

    override func layout() {
        super.layout()
        onResize?(frame.size)
    }
}

/// A SwiftUI wrapper around SwiftTerm's TerminalView embedded in a scroll view
struct TerminalContainerView: NSViewRepresentable {
    /// The terminal view controller that manages the underlying terminal
    let terminalController: TerminalController

    func makeNSView(context: Context) -> ResizingScrollView {
        let scrollView = terminalController.scrollView

        // Set up resize callback
        scrollView.onResize = { [weak terminalController] size in
            terminalController?.updateMinimumSize(size)
        }

        return scrollView
    }

    func updateNSView(_ nsView: ResizingScrollView, context: Context) {
        // Also update on SwiftUI layout changes
        terminalController.updateMinimumSize(nsView.frame.size)
    }
}

/// Controller that manages a SwiftTerm TerminalView with fixed dimensions
@Observable
@MainActor
final class TerminalController: @unchecked Sendable {
    /// The scroll view containing the terminal
    let scrollView: ResizingScrollView

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
    private var terminalSize = NSSize(width: 800, height: 600)

    /// Whether the user has scrolled away from the bottom
    private(set) var isScrolledUp = false

    /// Minimum size for the terminal (visible scroll view area)
    private var minimumSize = NSSize.zero

    init() {
        // Create terminal view
        self.terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Create scroll view to contain the terminal
        self.scrollView = ResizingScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Use flipped clip view so content aligns to top instead of bottom
        let flippedClipView = FlippedClipView()
        flippedClipView.documentView = terminalView
        scrollView.contentView = flippedClipView

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)

        // Use overlay scrollers so they don't take up content space
        scrollView.scrollerStyle = .overlay

        // Ensure no automatic content insets
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // Disable automatic content resizing - we want fixed terminal size
        scrollView.autoresizesSubviews = false
        terminalView.autoresizingMask = []

        setupTerminal()
    }

    private func setupTerminal() {
        // Configure terminal appearance
        updateFont()

        // Set up terminal colors (dark theme by default)
        applyDarkTheme()
    }

    /// Feeds raw data (including ANSI escape sequences) to the terminal
    func feed(_ data: Data) {
        let bytes = [UInt8](data)
        terminalView.feed(byteArray: bytes[...])
    }

    /// Clears the terminal display
    func clear() {
        // Send clear screen escape sequence
        feed(Data("\u{1b}[2J\u{1b}[H".utf8))
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

    /// Updates the minimum size for the terminal view (called when scroll view resizes)
    func updateMinimumSize(_ size: NSSize) {
        minimumSize = size
        updateTerminalFrameSize()
    }

    /// Updates the terminal frame size based on current font and dimensions
    private func updateTerminalFrameSize() {
        // Calculate cell size from font metrics (matches SwiftTerm's computeFontDimensions)
        let cellSize = calculateCellSize()

        // Calculate required size
        // Add buffer to compensate for SwiftTerm's internal scroller
        // See: docs/swiftterm-sizing.md for details
        let width = CGFloat(columns) * cellSize.width + FontMetrics.horizontalBuffer
        let height = CGFloat(rows) * cellSize.height

        // Use the larger of terminal size or minimum (visible) size
        let finalWidth = max(width, minimumSize.width)
        let finalHeight = max(height, minimumSize.height)

        terminalSize = NSSize(width: finalWidth, height: finalHeight)

        // Update the terminal view frame
        terminalView.frame = NSRect(origin: .zero, size: terminalSize)
    }

    /// Calculates the cell size based on the current font
    private func calculateCellSize() -> CGSize {
        FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
    }

    /// Scrolls to the bottom of the terminal
    func scrollToBottom() {
        terminalView.scroll(toPosition: 1)
        isScrolledUp = false
    }

    // MARK: - Theme Support

    func applyDarkTheme() {
        // Default dark theme colors
        let bgColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        terminalView.nativeBackgroundColor = bgColor
        scrollView.backgroundColor = bgColor
    }

    func applyLightTheme() {
        let bgColor = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        terminalView.nativeBackgroundColor = bgColor
        scrollView.backgroundColor = bgColor
    }

    func applyTheme(_ theme: TerminalTheme) {
        switch theme {
        case .defaultDark,
             .solarizedDark:
            applyDarkTheme()
        case .defaultLight,
             .solarizedLight:
            applyLightTheme()
        }
    }

    // MARK: - Private Helpers

    private func updateFont() {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.font = font

        // Recalculate terminal size with new font
        updateTerminalFrameSize()
    }
}
