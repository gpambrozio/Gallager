import AppKit
import SwiftTerm
import SwiftUI

/// A SwiftUI wrapper around SwiftTerm's TerminalView
struct TerminalContainerView: NSViewRepresentable {
    /// The terminal view controller that manages the underlying terminal
    let terminalController: TerminalController

    func makeNSView(context: Context) -> TerminalView {
        terminalController.terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Updates are handled by the TerminalController
    }
}

/// Controller that manages a SwiftTerm TerminalView
@Observable
@MainActor
final class TerminalController: @unchecked Sendable {
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

    /// Number of columns
    private(set) var columns: Int = 80

    /// Number of rows
    private(set) var rows: Int = 24

    /// Whether the user has scrolled away from the bottom
    private(set) var isScrolledUp: Bool = false

    init() {
        self.terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setupTerminal()
    }

    private func setupTerminal() {
        // Configure terminal appearance
        updateFont()

        // Set up terminal colors (dark theme by default)
        applyDarkTheme()

        // Make it read-only - we're just displaying, not accepting input
        // SwiftTerm doesn't have a direct read-only mode, but we can ignore input
        // by not connecting it to a process
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

    /// Resizes the terminal to the specified dimensions
    func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        terminalView.getTerminal().resize(cols: columns, rows: rows)
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
        terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    }

    func applyLightTheme() {
        terminalView.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        terminalView.nativeBackgroundColor = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
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
    }
}
