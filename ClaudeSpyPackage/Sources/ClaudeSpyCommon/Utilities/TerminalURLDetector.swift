import Foundation

/// Detects plain-text URLs in terminal buffer text at a given grid position.
///
/// Platform-agnostic: takes a closure to retrieve line text rather than depending on SwiftTerm directly.
/// Callers bridge to SwiftTerm via: `{ terminal.getLine(row: $0)?.translateToString(trimRight: true) }`
public enum TerminalURLDetector {
    /// URL pattern matching common schemes.
    /// Matches http://, https://, and ftp:// URLs. file:// is excluded for security.
    private static let urlPattern: String = {
        let schemes = "https?://|ftp://"
        // URL characters: anything except whitespace and common terminal delimiters
        let urlChars = "[^\\s<>\"'`\\]\\)\\}\\|]"
        return "(?:\(schemes))\(urlChars)+"
    }()

    // Pattern is a compile-time constant; failure is a programmer error
    private static let urlRegex = try! NSRegularExpression(pattern: urlPattern, options: [])

    /// Represents a detected URL with its column range within a terminal line.
    public struct DetectedURL {
        public let url: String
        public let startCol: Int
        public let endCol: Int
    }

    /// Finds all URLs in the text returned by `lineText` for the given row.
    ///
    /// - Parameters:
    ///   - row: The row index to pass to `lineText`.
    ///   - lineText: Closure that returns the text content of a terminal line, or `nil` if the row is invalid.
    /// - Returns: Detected URLs with their column ranges.
    public static func detectURLs(row: Int, lineText: (Int) -> String?) -> [DetectedURL] {
        guard let text = lineText(row), !text.isEmpty else { return [] }

        let nsText = text as NSString
        let matches = urlRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        return matches.compactMap { match in
            let urlString = nsText.substring(with: match.range)
            let cleaned = cleanTrailingPunctuation(urlString)
            guard URL(string: cleaned) != nil else { return nil }

            // Map NSRange to column positions using UTF-16 lengths for consistency
            let startCol = match.range.location
            let endCol = startCol + (cleaned as NSString).length
            return DetectedURL(url: cleaned, startCol: startCol, endCol: endCol)
        }
    }

    /// Finds the URL at a specific column position in a terminal row.
    ///
    /// - Parameters:
    ///   - col: The column position to check.
    ///   - row: The row index to pass to `lineText`.
    ///   - lineText: Closure that returns the text content of a terminal line, or `nil` if the row is invalid.
    /// - Returns: The URL string if one exists at the given position, otherwise `nil`.
    public static func urlAt(col: Int, row: Int, lineText: (Int) -> String?) -> String? {
        let urls = detectURLs(row: row, lineText: lineText)
        return urls.first(where: { col >= $0.startCol && col < $0.endCol })?.url
    }

    /// Removes trailing punctuation that commonly follows URLs in text but isn't part of the URL.
    private static func cleanTrailingPunctuation(_ url: String) -> String {
        var result = url
        let trailingChars: Set<Character> = [".", ",", ";", ":", "!", "?"]
        while let last = result.last, trailingChars.contains(last) {
            result.removeLast()
        }
        // Handle matched brackets/parens: if URL ends with ) but has no matching (
        if result.hasSuffix(")"), !result.contains("(") {
            result.removeLast()
        }
        return result
    }
}
