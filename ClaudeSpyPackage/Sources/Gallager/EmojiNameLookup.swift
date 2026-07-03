import Foundation
import GallagerEmoji

/// Resolves emoji from a free-form name or description for the CLI's
/// `set-emoji` and `find-emoji` commands.
///
/// Thin adapter over ``GallagerEmoji/EmojiDatabase``, the same keyword-aware
/// index the Mac/iOS picker uses. Delegating here (rather than walking Unicode
/// scalar names as this used to) is what lets `find-emoji trash` resolve 🗑️:
/// Foundation only exposes the formal name `WASTEBASKET`, but the shared table
/// carries the CLDR synonyms "trash", "bin", "garbage", and "can" (issue #630).
enum EmojiNameLookup {
    struct Match: Hashable {
        /// The renderable emoji string (includes VS16 for text-default glyphs
        /// so terminals show color, not a monochrome text variant).
        let emoji: String
        /// The emoji's CLDR display name (lowercase, e.g. `wastebasket`).
        let name: String
    }

    /// Returns matches for `query`, best first. An exact (case-insensitive) hit
    /// on the full name short-circuits to a single result so `set-emoji rocket`
    /// resolves 🚀 unambiguously; otherwise every whitespace-separated word must
    /// appear in the candidate's name or one of its keyword synonyms.
    static func search(query: String) -> [Match] {
        EmojiDatabase.shared.search(query).map { emoji in
            Match(emoji: emoji.glyph, name: emoji.label)
        }
    }
}
