import Foundation
import RegexBuilder

/// Detects plain-text URLs in terminal buffer text at a given grid position.
///
/// Platform-agnostic: takes a closure to retrieve line text rather than depending on SwiftTerm directly.
/// Callers bridge to SwiftTerm via: `{ terminal.getLine(row: $0)?.translateToString(trimRight: true) }`
public enum TerminalURLDetector {
    /// Matches http://, https://, and ftp:// URLs.
    /// file:// is excluded for security (prevents opening local files from remote terminal sessions).
    private nonisolated(unsafe) static let urlRegex = Regex {
        ChoiceOf {
            "http://"
            "https://"
            "ftp://"
        }
        OneOrMore {
            CharacterClass(
                .anyOf("<>\"'`])}|"),
                .whitespace
            ).inverted
        }
    }

    /// Represents a detected URL with its column range within a terminal line.
    public struct DetectedURL: Sendable {
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

        return text.matches(of: urlRegex).compactMap { match in
            let urlString = String(match.output)
            let cleaned = cleanTrailingPunctuation(urlString)
            guard
                let parsedURL = URL(string: cleaned),
                let host = parsedURL.host, !host.isEmpty else { return nil }

            // Map match range to UTF-16 column positions for SwiftTerm grid consistency
            let startCol = text.utf16.distance(from: text.utf16.startIndex, to: match.range.lowerBound)
            let endCol = startCol + cleaned.utf16.count
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
