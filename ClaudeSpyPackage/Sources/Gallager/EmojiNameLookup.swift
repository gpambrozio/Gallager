import Foundation

/// Resolves emoji from a free-form name or description by walking the Unicode
/// emoji range and matching against `Unicode.Scalar.Properties.name`.
///
/// Built so the CLI's `set-emoji` and `find-emoji` commands can accept human
/// input like `rocket`, `fire`, or `"smiling face"` without bundling a separate
/// shortcode database — Foundation already exposes the official Unicode names.
enum EmojiNameLookup {
    struct Match: Sendable, Hashable {
        /// The renderable emoji string. Includes VS16 for scalars that don't
        /// default to emoji presentation, so terminals show them as emoji and
        /// not as monochrome text glyphs.
        let emoji: String
        /// The official Unicode name (UPPERCASE).
        let name: String
    }

    /// Lazily built once per process. The CLI is short-lived so the cost only
    /// matters for commands that actually consult the database.
    static let database: [Match] = buildDatabase()

    private static func buildDatabase() -> [Match] {
        var result: [Match] = []
        // 0x1FAFF covers Symbols & Pictographs Extended-A; anything above that
        // is not used for emoji as of Unicode 15.
        for codepoint in 0x80...0x1FAFF {
            guard let scalar = Unicode.Scalar(codepoint) else { continue }
            guard scalar.properties.isEmoji else { continue }
            guard let name = scalar.properties.name else { continue }
            // Force colorful emoji presentation for scalars (e.g. ❤, ☀, ☁) that
            // would otherwise render as text by default.
            let display = scalar.properties.isEmojiPresentation
                ? String(scalar)
                : String(scalar) + "\u{FE0F}"
            result.append(Match(emoji: display, name: name))
        }
        return result
    }

    /// Returns matches for `query`. An exact (case-insensitive) hit on the full
    /// Unicode name short-circuits and returns just that emoji. Otherwise every
    /// whitespace-separated word in the query must appear as a substring of the
    /// candidate's name.
    static func search(query: String) -> [Match] {
        let upper = query.uppercased()
        if let exact = database.first(where: { $0.name == upper }) {
            return [exact]
        }
        let words = upper
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return database.filter { match in
            words.allSatisfy { match.name.contains($0) }
        }
    }
}
