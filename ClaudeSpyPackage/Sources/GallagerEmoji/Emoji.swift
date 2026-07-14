import Foundation

/// A single searchable emoji, backed by the CLDR annotation data baked into
/// ``EmojiData`` at build time.
///
/// Both the Mac/iOS picker and the `gallager find-emoji` / `set-emoji` CLI
/// resolve queries through the same ``Emoji`` values, so "trash", "bin", and
/// "garbage" all surface 🗑️ regardless of surface — the whole point of
/// issue #630. `keywords` carries the synonyms Foundation's formal Unicode
/// name (`WASTEBASKET`) never exposed.
public struct Emoji: Sendable, Hashable, Identifiable {
    /// The renderable emoji string, including VS16 for glyphs that would
    /// otherwise fall back to monochrome text presentation (🗑️, ✈️, ❤️).
    public let glyph: String
    /// The CLDR display name (lowercase, e.g. `smiling face with heart-eyes`).
    public let label: String
    /// CLDR annotation keywords plus emoticons — the synonym set that makes
    /// search forgiving. May include multi-word entries (`red heart`).
    public let keywords: [String]
    /// The emojibase category number (see ``EmojiCategory``).
    public let group: Int
    /// The Unicode emoji version the glyph was introduced in, used to hide
    /// emoji newer than the running OS can render.
    public let version: Double
    /// Stable display position within the full, version-filtered table.
    public let order: Int

    /// Lowercased `label` + keywords as one blob, handy for substring scoring.
    let searchBlob: String
    /// Lowercased word tokens from the label and keywords, split on whitespace
    /// and hyphens. Search matches a query word when it *prefixes* one of these
    /// tokens — so "bin" finds the wastebasket (keyword `bin`) but not
    /// "clim**bin**g", and "roc" still finds 🚀 as you type.
    let searchTokens: [String]

    public var id: String {
        glyph
    }

    public init(
        glyph: String,
        label: String,
        keywords: [String],
        group: Int,
        version: Double,
        order: Int
    ) {
        self.glyph = glyph
        self.label = label
        self.keywords = keywords
        self.group = group
        self.version = version
        self.order = order
        let blob = ([label] + keywords).joined(separator: " ")
        self.searchBlob = blob.lowercased()
        self.searchTokens = Array(Set(Emoji.tokenize(blob)))
    }

    /// Splits `text` into lowercased word tokens on whitespace and hyphens.
    /// Used for both emoji tokens and query words so "heart-eyes" and
    /// "heart eyes" tokenize identically.
    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map(String.init)
    }

    /// Whether some token starts with `queryWord` (already lowercased).
    func matchesWordPrefix(_ queryWord: String) -> Bool {
        searchTokens.contains { $0.hasPrefix(queryWord) }
    }
}
