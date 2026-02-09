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
    /// This exactly matches SwiftTerm's `computeFontDimensions()` method.
    /// - macOS: `NSFont.glyph(withName:)` + `NSFont.advancement(forGlyph:)`
    /// - iOS: `"W".size(withAttributes:).width`
    ///
    /// - Parameters:
    ///   - fontName: Name of the font (e.g., "SF Mono", "Menlo")
    ///   - fontSize: Size of the font in points
    /// - Returns: The size of a single character cell
    public static func calculateCellSize(fontName: String, fontSize: CGFloat) -> CGSize {
        let font = createFont(name: fontName, size: fontSize)
        return calculateCellSize(font: font)
    }

    /// Calculates the cell size for an existing font.
    ///
    /// This exactly matches SwiftTerm's `computeFontDimensions()` method.
    /// Use this overload when you already have a font reference (e.g., from `TerminalView.font`).
    ///
    /// - Parameter font: The monospace font to measure (NSFont on macOS, UIFont on iOS)
    /// - Returns: The size of a single character cell
    public static func calculateCellSize(font: CTFont) -> CGSize {
        // Height: sum of ascent, descent, and leading (same on both platforms)
        let lineAscent = CTFontGetAscent(font)
        let lineDescent = CTFontGetDescent(font)
        let lineLeading = CTFontGetLeading(font)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)

        // Width: SwiftTerm uses different methods per platform
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            // macOS: Use NSFont.glyph(withName:) + advancement (matches SwiftTerm exactly)
            let nsFont = font as NSFont
            let glyph = nsFont.glyph(withName: "W")
            let cellWidth = nsFont.advancement(forGlyph: glyph).width
        #else
            // iOS: Use NSAttributedString sizing (matches SwiftTerm's iOS implementation)
            let uiFont = font as UIFont
            let fontAttributes: [NSAttributedString.Key: Any] = [.font: uiFont]
            let cellWidth = "W".size(withAttributes: fontAttributes).width
        #endif

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
}
