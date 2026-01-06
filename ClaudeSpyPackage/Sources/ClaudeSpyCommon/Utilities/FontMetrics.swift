import CoreText
import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Utility for calculating terminal font metrics.
///
/// Uses CoreText APIs that work on both macOS and iOS to calculate
/// precise monospace font cell dimensions matching SwiftTerm's internal calculations.
///
/// See docs/swiftterm-sizing.md for detailed analysis of SwiftTerm's sizing calculations.
@MainActor
public enum FontMetrics {
    /// Calculates the cell size for a monospace font.
    ///
    /// This exactly matches SwiftTerm's `computeFontDimensions()` method:
    /// https://github.com/migueldeicaza/SwiftTerm/blob/0b8d99bd19b694df44e1ccaa3891309719d34330/Sources/SwiftTerm/Apple/AppleTerminalView.swift#L142-L167
    ///
    /// - Parameters:
    ///   - fontName: Name of the font (e.g., "SF Mono", "Menlo")
    ///   - fontSize: Size of the font in points
    /// - Returns: The size of a single character cell
    public static func calculateCellSize(fontName: String, fontSize: CGFloat) -> CGSize {
        let font = createFont(name: fontName, size: fontSize)

        // Width: use glyph advancement for "W"
        // SwiftTerm uses this specific character for width calculation
        let cellWidth = glyphAdvanceWidth(for: font, character: "W")

        // Height: sum of ascent, descent, and leading (same as SwiftTerm)
        let lineAscent = CTFontGetAscent(font)
        let lineDescent = CTFontGetDescent(font)
        let lineLeading = CTFontGetLeading(font)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)

        return CGSize(width: max(1, cellWidth), height: max(1, cellHeight))
    }

    /// Returns the width of SwiftTerm's internal scroller.
    ///
    /// On macOS, SwiftTerm's MacTerminalView uses a legacy-style NSScroller that reserves horizontal space.
    /// On iOS, SwiftTerm uses UIScrollView which overlays the content (no reserved space).
    ///
    /// - Returns: The scroller width in points (macOS) or 0 (iOS)
    public static var swiftTermScrollerWidth: CGFloat {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        #else
        return 0
        #endif
    }

    /// Buffer to add to terminal width to compensate for SwiftTerm's internal scroller.
    ///
    /// This includes the scroller width plus a small rounding buffer for font metric differences.
    /// On iOS, this is just the rounding buffer since iOS uses overlay scrollers.
    public static var horizontalBuffer: CGFloat {
        swiftTermScrollerWidth + 4
    }

    // MARK: - Private Helpers

    private static func createFont(name: String, size: CGFloat) -> CTFont {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // macOS: Use NSFont for better font name resolution, then convert to CTFont
        let nsFont = NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return nsFont as CTFont
        #else
        // iOS: Use UIFont for better font name resolution, then convert to CTFont
        let uiFont = UIFont(name: name, size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return uiFont as CTFont
        #endif
    }

    private static func glyphAdvanceWidth(for font: CTFont, character: Character) -> CGFloat {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // macOS: Use NSFont's glyph methods for precise measurement
        let nsFont = font as NSFont
        let glyph = nsFont.glyph(withName: String(character))
        return nsFont.advancement(forGlyph: glyph).width
        #else
        // iOS: Use CTFont to get glyph advancement
        var unichars = [UniChar](String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        return advance.width
        #endif
    }
}
