import AppKit
import CoreText
import SwiftTerm
import SwiftUI

/// A SwiftUI wrapper around SwiftTerm's TerminalView embedded in a scroll view
struct TerminalContainerView: NSViewRepresentable {
    /// The terminal view controller that manages the underlying terminal
    let terminalController: TerminalController

    func makeNSView(context: Context) -> NSScrollView {
        terminalController.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Updates are handled by the TerminalController
    }
}

/// Controller that manages a SwiftTerm TerminalView with fixed dimensions
@Observable
@MainActor
final class TerminalController: @unchecked Sendable {
    /// The scroll view containing the terminal
    let scrollView: NSScrollView

    /// The underlying SwiftTerm terminal view
    let terminalView: TerminalView

    /// Font name for the terminal
    var fontName: String = "SF Mono" {
        didSet { updateFont() }
    }

    /// Font size for the terminal
    var fontSize: CGFloat = 12 {
        didSet { updateFont() }
    }

    /// Number of columns (fixed to pane size)
    private(set) var columns: Int = 80

    /// Number of rows (fixed to pane size)
    private(set) var rows: Int = 24

    /// The fixed size of the terminal content
    private var terminalSize: NSSize = NSSize(width: 800, height: 600)

    /// Whether the user has scrolled away from the bottom
    private(set) var isScrolledUp: Bool = false

    init() {
        // Create terminal view
        self.terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Create scroll view to contain the terminal
        self.scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = terminalView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

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
        terminalView.feed(byteArray: ArraySlice(data))
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
        // Calculate cell size from font metrics
        let cellSize = calculateCellSize()

        // Calculate required size
        let width = CGFloat(columns) * cellSize.width
        let height = CGFloat(rows) * cellSize.height

        terminalSize = NSSize(width: width, height: height)

        // Update the terminal view frame
        terminalView.frame = NSRect(origin: .zero, size: terminalSize)
    }

    /// Calculates the cell size based on the current font
    /// Matches SwiftTerm's internal computeFontDimensions() method exactly
    /// See: https://github.com/migueldeicaza/SwiftTerm/blob/b14d7b0b666180ebcef8beda988e1865b83eb6f2/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L156
    private func calculateCellSize() -> CGSize {
        let font = terminalView.font
        let ctFont = font as CTFont

        // Width: use glyph advancement for "W" (macOS approach)
        let glyph = font.glyph(withName: "W")
        let cellWidth = font.advancement(forGlyph: glyph).width

        // Height: sum of ascent, descent, and leading
        let lineAscent = CTFontGetAscent(ctFont)
        let lineDescent = CTFontGetDescent(ctFont)
        let lineLeading = CTFontGetLeading(ctFont)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)

        return CGSize(width: max(1, cellWidth), height: max(1, cellHeight))
    }

    /// Scrolls to the bottom of the terminal
    func scrollToBottom() {
        terminalView.scroll(toPosition: 1.0)
        isScrolledUp = false
    }

    /// Gets the terminal's scrollback content as data
    func getScrollbackContent() -> Data {
        terminalView.getTerminal().getBufferAsData()
    }

    // MARK: - Theme Support

    func applyDarkTheme() {
        // Default dark theme colors
        let bgColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        terminalView.nativeBackgroundColor = bgColor
        scrollView.backgroundColor = bgColor
    }

    func applyLightTheme() {
        let bgColor = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        terminalView.nativeBackgroundColor = bgColor
        scrollView.backgroundColor = bgColor
    }

    func applyTheme(_ theme: TerminalTheme) {
        switch theme {
        case .defaultDark, .solarizedDark:
            applyDarkTheme()
        case .defaultLight, .solarizedLight:
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
