import Foundation

/// The parsed, searchable emoji table shared by the picker UI and the CLI.
///
/// Parsing the ~1900-row ``EmojiData/table`` is done once and cached on
/// ``shared``. Search matches against each emoji's label *and* its CLDR
/// keyword synonyms, which is what lets "trash" resolve 🗑️ where the old
/// Unicode-name lookup (`WASTEBASKET`) could not.
public struct EmojiDatabase: Sendable {
    /// Process-wide instance. The table is immutable, so a single parse is
    /// reused everywhere.
    public static let shared = EmojiDatabase()

    /// Highest Unicode emoji version to surface. The deployment floor
    /// (macOS 15 / iOS 18) renders through Emoji 15.1; anything newer would
    /// draw as a "tofu" box, so it is hidden. Bump this — and regenerate
    /// `EmojiData.swift` if needed — when the floor rises.
    public static let maxEmojiVersion = 15.1

    /// Every surfaced emoji in display order (grouped by category, CLDR order
    /// within each category).
    public let all: [Emoji]

    public init(maxVersion: Double = EmojiDatabase.maxEmojiVersion) {
        self.all = Self.parse(EmojiData.table, maxVersion: maxVersion)
    }

    // MARK: - Parsing

    private static func parse(_ table: String, maxVersion: Double) -> [Emoji] {
        var result: [Emoji] = []
        result.reserveCapacity(2_000)
        var order = 0
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            // glyph, label, keywords, group, version
            guard fields.count == 5 else { continue }
            let glyph = String(fields[0])
            let label = String(fields[1])
            let keywords = fields[2].isEmpty
                ? []
                : fields[2].split(separator: "|").map(String.init)
            guard
                let group = Int(fields[3]),
                let version = Double(fields[4])
            else { continue }
            guard version <= maxVersion else { continue }
            result.append(Emoji(
                glyph: glyph,
                label: label,
                keywords: keywords,
                group: group,
                version: version,
                order: order
            ))
            order += 1
        }
        return result
    }

    // MARK: - Browsing

    /// Emoji grouped into the picker's sections, in ``EmojiCategory`` order.
    /// Empty categories are omitted.
    public func categorized() -> [(category: EmojiCategory, emoji: [Emoji])] {
        var buckets: [EmojiCategory: [Emoji]] = [:]
        for emoji in all {
            buckets[EmojiCategory.from(group: emoji.group), default: []].append(emoji)
        }
        return EmojiCategory.allCases.compactMap { category in
            guard let emoji = buckets[category], !emoji.isEmpty else { return nil }
            return (category, emoji)
        }
    }

    // MARK: - Searching

    /// Emoji matching `rawQuery`, best matches first.
    ///
    /// Rules, in order of intent:
    ///  * An exact (case-insensitive) hit on the full label short-circuits to a
    ///    single result — so `set-emoji rocket` resolves 🚀 unambiguously.
    ///  * Otherwise every word in the query must *prefix* a word of the emoji's
    ///    label or keywords. Prefix (not substring) matching keeps "bin" off
    ///    "clim**bin**g" while still matching as you type ("roc" → 🚀).
    ///  * Results are ranked so name matches beat keyword-synonym matches, and
    ///    shorter/earlier labels beat longer ones, keeping the most canonical
    ///    glyph at the top of ambiguous queries.
    public func search(_ rawQuery: String) -> [Emoji] {
        let query = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return [] }

        if let exact = all.first(where: { $0.label.lowercased() == query }) {
            return [exact]
        }

        // Query words are tokenized the same way as emoji tokens so "heart-eyes"
        // splits into "heart"/"eyes". Each must prefix some token of a candidate.
        let words = Emoji.tokenize(query)
        guard !words.isEmpty else { return [] }

        let scored: [(emoji: Emoji, score: Int)] = all.compactMap { emoji in
            guard words.allSatisfy({ emoji.matchesWordPrefix($0) }) else { return nil }
            return (emoji, Self.score(emoji, query: query, words: words))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.emoji.label.count != rhs.emoji.label.count {
                    return lhs.emoji.label.count < rhs.emoji.label.count
                }
                return lhs.emoji.order < rhs.emoji.order
            }
            .map(\.emoji)
    }

    /// Higher is a better match. A match against the emoji's *name* outranks one
    /// that only hit a keyword synonym, so naming an emoji directly floats it to
    /// the top while synonym hits still show up below.
    private static func score(_ emoji: Emoji, query: String, words: [String]) -> Int {
        let label = emoji.label.lowercased()
        let labelWords = Emoji.tokenize(label)
        if label == query { return 1_000 }
        if label.hasPrefix(query) { return 600 }
        // Every query word is a whole word of the label (e.g. "bin" in
        // "litter in bin sign").
        if words.allSatisfy({ word in labelWords.contains(word) }) { return 500 }
        // Every query word is an exact keyword synonym (e.g. "can" → the
        // wastebasket's `can`). A deliberate synonym beats an incidental prefix
        // of an unrelated word ("candy"), so this ranks above prefix matches.
        if words.allSatisfy({ word in emoji.keywords.contains { $0.lowercased() == word } }) { return 450 }
        // Every query word prefixes a label word (e.g. "roc" → "rocket").
        if words.allSatisfy({ word in labelWords.contains { $0.hasPrefix(word) } }) { return 400 }
        // Fell through on a keyword prefix (the only remaining way to have
        // matched at all).
        return 100
    }
}
