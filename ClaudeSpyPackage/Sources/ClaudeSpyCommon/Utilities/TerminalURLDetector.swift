import Foundation
import RegexBuilder

/// Detects URLs in terminal buffer text via regex and OSC 8 hyperlink payloads.
///
/// Platform-agnostic: takes closures to retrieve line text and per-cell payloads rather than
/// depending on SwiftTerm directly.
///
/// Callers bridge to SwiftTerm via:
/// - `lineText`: `{ terminal.getLine(row: $0)?.translateToString(trimRight: true) }`
/// - `cellPayload`: `{ col, row in terminal.getLine(row: row)?[col].getPayload() as? String }`
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

    /// The source that detected a URL.
    public enum Source: Sendable, Hashable {
        /// Detected via OSC 8 terminal escape sequence (higher priority).
        case escapeSequence
        /// Detected via plain-text regex matching.
        case regex
    }

    /// Represents a detected URL with its column range within a terminal line.
    public struct DetectedURL: Sendable, Hashable {
        public let url: String
        public let startCol: Int
        public let endCol: Int
        public let source: Source
    }

    /// Finds all URLs in a terminal row by combining OSC 8 hyperlink payloads and regex detection.
    ///
    /// OSC 8 links take priority: any regex-detected URL whose range overlaps an OSC 8 link is discarded.
    ///
    /// - Parameters:
    ///   - row: The viewport row index.
    ///   - cols: The number of columns in the terminal line (for payload scanning).
    ///   - lineText: Closure that returns the text content of a terminal line, or `nil` if the row is invalid.
    ///   - cellPayload: Closure that returns the OSC 8 hyperlink URL for a cell, or `nil` if none.
    /// - Returns: Detected URLs with their column ranges, sorted by start column.
    public static func detectURLs(
        row: Int,
        cols: Int,
        lineText: (Int) -> String?,
        cellPayload: (Int, Int) -> String?
    ) -> [DetectedURL] {
        let oscURLs = detectOSC8URLs(row: row, cols: cols, cellPayload: cellPayload)
        let regexURLs = detectRegexURLs(row: row, lineText: lineText)

        guard !oscURLs.isEmpty else { return regexURLs }
        guard !regexURLs.isEmpty else { return oscURLs }

        // Filter out regex URLs that overlap with any OSC 8 URL
        let filtered = regexURLs.filter { regexURL in
            !oscURLs.contains { oscURL in
                regexURL.startCol < oscURL.endCol && regexURL.endCol > oscURL.startCol
            }
        }

        return (oscURLs + filtered).sorted { $0.startCol < $1.startCol }
    }

    /// Finds all URLs in a terminal row using regex only (no OSC 8 support).
    ///
    /// - Parameters:
    ///   - row: The row index to pass to `lineText`.
    ///   - lineText: Closure that returns the text content of a terminal line, or `nil` if the row is invalid.
    /// - Returns: Detected URLs with their column ranges.
    public static func detectURLs(row: Int, lineText: (Int) -> String?) -> [DetectedURL] {
        detectRegexURLs(row: row, lineText: lineText)
    }

    /// Finds the URL at a specific column position in a terminal row (with OSC 8 support).
    ///
    /// - Parameters:
    ///   - col: The column position to check.
    ///   - row: The viewport row index.
    ///   - cols: The number of columns in the terminal line.
    ///   - lineText: Closure that returns the text content of a terminal line.
    ///   - cellPayload: Closure that returns the OSC 8 hyperlink URL for a cell, or `nil`.
    /// - Returns: The URL string if one exists at the given position, otherwise `nil`.
    public static func urlAt(
        col: Int,
        row: Int,
        cols: Int,
        lineText: (Int) -> String?,
        cellPayload: (Int, Int) -> String?
    ) -> String? {
        // Check OSC 8 first (higher priority)
        if let payload = cellPayload(col, row) {
            return payload
        }
        // Fall back to regex
        return urlAt(col: col, row: row, lineText: lineText)
    }

    /// Finds the URL at a specific column position using regex only.
    public static func urlAt(col: Int, row: Int, lineText: (Int) -> String?) -> String? {
        let urls = detectRegexURLs(row: row, lineText: lineText)
        return urls.first(where: { col >= $0.startCol && col < $0.endCol })?.url
    }

    // MARK: - Private

    /// Scans a terminal row for consecutive runs of cells with the same OSC 8 hyperlink payload.
    private static func detectOSC8URLs(
        row: Int,
        cols: Int,
        cellPayload: (Int, Int) -> String?
    ) -> [DetectedURL] {
        var results: [DetectedURL] = []
        var col = 0

        while col < cols {
            guard let url = cellPayload(col, row), !url.isEmpty else {
                col += 1
                continue
            }

            // Found start of an OSC 8 link — scan forward for contiguous cells with the same URL
            let startCol = col
            col += 1
            while col < cols, cellPayload(col, row) == url {
                col += 1
            }

            results.append(DetectedURL(url: url, startCol: startCol, endCol: col, source: .escapeSequence))
        }

        return results
    }

    /// Detects URLs using regex matching on the plain text of a terminal line.
    private static func detectRegexURLs(row: Int, lineText: (Int) -> String?) -> [DetectedURL] {
        guard let text = lineText(row), !text.isEmpty else { return [] }

        return text.matches(of: urlRegex).compactMap { match in
            let urlString = String(match.output)
            let cleaned = cleanTrailingPunctuation(urlString)
            guard
                let parsedURL = URL(string: cleaned),
                let host = parsedURL.host(percentEncoded: false), !host.isEmpty else { return nil }

            // Map match range to UTF-16 column positions for SwiftTerm grid consistency
            let startCol = text.utf16.distance(from: text.utf16.startIndex, to: match.range.lowerBound)
            let endCol = startCol + cleaned.utf16.count
            return DetectedURL(url: cleaned, startCol: startCol, endCol: endCol, source: .regex)
        }
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
