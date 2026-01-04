import AppKit
import CoreText

/// Utility for calculating terminal font metrics
///
/// See docs/swiftterm-sizing.md for detailed analysis of SwiftTerm's sizing calculations.
@MainActor
enum FontMetrics {
    /// Calculates the cell size for a monospace font.
    ///
    /// This exactly matches SwiftTerm's `computeFontDimensions()` method:
    /// https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L142-L167
    ///
    /// - Parameters:
    ///   - fontName: Name of the font (e.g., "SF Mono")
    ///   - fontSize: Size of the font in points
    /// - Returns: The size of a single character cell
    static func calculateCellSize(fontName: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let ctFont = font as CTFont

        // Width: use glyph advancement for "W" (macOS approach)
        // SwiftTerm uses this specific character for width calculation
        let glyph = font.glyph(withName: "W")
        let cellWidth = font.advancement(forGlyph: glyph).width

        // Height: sum of ascent, descent, and leading (same as SwiftTerm)
        let lineAscent = CTFontGetAscent(ctFont)
        let lineDescent = CTFontGetDescent(ctFont)
        let lineLeading = CTFontGetLeading(ctFont)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)

        return CGSize(width: max(1, cellWidth), height: max(1, cellHeight))
    }

    /// Returns the width of SwiftTerm's internal scroller.
    ///
    /// SwiftTerm's MacTerminalView uses a legacy-style NSScroller that reserves horizontal space.
    /// When calculating effective width, SwiftTerm subtracts this scroller width:
    /// https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Mac/MacTerminalView.swift#L348-L351
    ///
    /// The scroller is set up with legacy style here:
    /// https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Mac/MacTerminalView.swift#L304-L320
    ///
    /// - Returns: The scroller width in points (typically ~15px on modern macOS)
    static var swiftTermScrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    /// Buffer to add to terminal width to compensate for SwiftTerm's internal scroller.
    ///
    /// This includes the scroller width plus a small rounding buffer for font metric differences.
    static var horizontalBuffer: CGFloat {
        swiftTermScrollerWidth + 4
    }
}
