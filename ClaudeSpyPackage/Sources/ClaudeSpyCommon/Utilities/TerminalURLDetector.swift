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

    /// Schemes considered safe to render and open by default. `file://` is
    /// excluded so OSC 8 hyperlinks emitted by a remote tmux session can't
    /// trick a viewer into opening local files. Callers running against a
    /// trusted local terminal (e.g. the host app's click handler) may pass
    /// a wider set via the `allowedSchemes:` parameter on `detectURLs` /
    /// `urlAt`.
    public static let defaultAllowedSchemes: Set<String> = ["http", "https", "ftp"]

    /// Finds all URLs in a terminal row by combining OSC 8 hyperlink payloads and regex detection.
    ///
    /// OSC 8 links take priority: any regex-detected URL whose range overlaps an OSC 8 link is discarded.
    ///
    /// - Parameters:
    ///   - row: The viewport row index.
    ///   - cols: The number of columns in the terminal line (for payload scanning).
    ///   - lineText: Closure that returns the text content of a terminal line, or `nil` if the row is invalid.
    ///   - cellPayload: Closure that returns the OSC 8 hyperlink URL for a cell, or `nil` if none.
    ///   - allowedSchemes: Set of URL schemes that are accepted from OSC 8
    ///     payloads. Defaults to `defaultAllowedSchemes`. The plain-text regex
    ///     match always uses the built-in http/https/ftp scheme list — this
    ///     only widens detection for explicit OSC 8 hyperlinks.
    /// - Returns: Detected URLs with their column ranges, sorted by start column.
    public static func detectURLs(
        row: Int,
        cols: Int,
        lineText: (Int) -> String?,
        cellPayload: (Int, Int) -> String?,
        allowedSchemes: Set<String> = defaultAllowedSchemes
    ) -> [DetectedURL] {
        let oscURLs = detectOSC8URLs(
            row: row,
            cols: cols,
            lineText: lineText,
            cellPayload: cellPayload,
            allowedSchemes: allowedSchemes
        )
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
    ///   - allowedSchemes: Set of URL schemes that are accepted from the OSC 8
    ///     payload at this position. Defaults to `defaultAllowedSchemes`. Pass
    ///     a wider set (e.g. including `"file"`) when running against a trusted
    ///     local terminal that wants to handle additional schemes itself.
    /// - Returns: The URL string if one exists at the given position, otherwise `nil`.
    public static func urlAt(
        col: Int,
        row: Int,
        cols: Int,
        lineText: (Int) -> String?,
        cellPayload: (Int, Int) -> String?,
        allowedSchemes: Set<String> = defaultAllowedSchemes
    ) -> String? {
        // Check OSC 8 first (higher priority)
        if
            let payload = cellPayload(col, row),
            let url = urlFromOSC8Payload(payload, allowedSchemes: allowedSchemes) {
            return url
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
    ///
    /// tmux's `capture-pane -e` may extend OSC 8 sequences across trailing spaces to the end
    /// of the line. We trim trailing whitespace from each detected range using the line text.
    private static func detectOSC8URLs(
        row: Int,
        cols: Int,
        lineText: (Int) -> String?,
        cellPayload: (Int, Int) -> String?,
        allowedSchemes: Set<String>
    ) -> [DetectedURL] {
        var results: [DetectedURL] = []
        var col = 0
        let text = lineText(row) ?? ""
        let utf16 = text.utf16

        while col < cols {
            guard
                let payload = cellPayload(col, row), !payload.isEmpty,
                let url = urlFromOSC8Payload(payload, allowedSchemes: allowedSchemes) else {
                col += 1
                continue
            }

            // Found start of an OSC 8 link — scan forward for contiguous cells with the same payload
            let startCol = col
            col += 1
            while col < cols, cellPayload(col, row) == payload {
                col += 1
            }

            // Trim trailing whitespace from the detected range using the line text.
            // tmux capture-pane may extend OSC 8 payloads across trailing spaces.
            // First clamp to text length — anything beyond the trimmed text is whitespace.
            var endCol = min(col, utf16.count)
            while endCol > startCol {
                let idx = utf16.index(utf16.startIndex, offsetBy: endCol - 1)
                guard let scalar = UnicodeScalar(utf16[idx]) else { break }
                let char = Character(scalar)
                if !char.isWhitespace { break }
                endCol -= 1
            }
            guard endCol > startCol else { continue }

            results.append(DetectedURL(url: url, startCol: startCol, endCol: endCol, source: .escapeSequence))
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

    /// Extracts the URL from a SwiftTerm OSC 8 payload string.
    ///
    /// SwiftTerm strips the leading `OSC 8 ;` (the code/data separator) before
    /// storing the payload, so the bytes saved on the cell look like
    /// `<params>;<URL>` — for example `;https://example.com` when params are
    /// empty, or `key=val;https://example.com` when params are present.
    /// We split on the first `;` to peel off the params and keep any
    /// semicolons inside the URL intact.
    ///
    /// Only URLs whose scheme is in `allowedSchemes` are returned. `file://`
    /// is excluded by default — pass it explicitly when running against a
    /// trusted local terminal that wants to handle file links.
    private static func urlFromOSC8Payload(_ payload: String, allowedSchemes: Set<String>) -> String? {
        guard let separator = payload.firstIndex(of: ";") else { return nil }
        let url = payload[payload.index(after: separator)...]
        guard !url.isEmpty else { return nil }
        // Validate scheme matches allowed list
        guard
            let parsed = URL(string: String(url)),
            let scheme = parsed.scheme?.lowercased(),
            allowedSchemes.contains(scheme)
        else { return nil }
        return String(url)
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
