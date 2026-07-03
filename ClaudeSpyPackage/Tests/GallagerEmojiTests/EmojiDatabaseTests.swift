import Testing
@testable import GallagerEmoji

/// Covers the keyword search that issue #630 is about: emoji have to be
/// findable by their common synonyms, not just their formal Unicode name.
struct EmojiDatabaseTests {
    let db = EmojiDatabase.shared

    // MARK: - Issue #630: the wastebasket must be findable by its synonyms

    @Test("\"trash\" resolves the wastebasket")
    func trashFindsWastebasket() {
        #expect(db.search("trash").first?.glyph == "🗑️")
    }

    @Test(
        "every synonym in the issue surfaces the wastebasket",
        arguments: ["trash", "bin", "garbage", "can", "rubbish", "waste"]
    )
    func synonymsFindWastebasket(term: String) {
        let glyphs = db.search(term).map(\.glyph)
        #expect(glyphs.contains("🗑️"), "search(\"\(term)\") should include 🗑️, got \(glyphs.prefix(5))")
    }

    @Test("search is case-insensitive")
    func caseInsensitive() {
        #expect(db.search("TRASH").first?.glyph == "🗑️")
        #expect(db.search("Trash").first?.glyph == "🗑️")
    }

    // MARK: - Exact-label short-circuit (CLI set-emoji relies on uniqueness)

    @Test("an exact label match returns a single result")
    func exactLabelShortCircuits() {
        let rocket = db.search("rocket")
        #expect(rocket.count == 1)
        #expect(rocket.first?.glyph == "🚀")
    }

    @Test("label matches outrank keyword-only matches")
    func labelBeatsKeyword() {
        // "bug" is 🐛's label; other emoji only list it as a keyword.
        #expect(db.search("bug").first?.glyph == "🐛")
    }

    // MARK: - Multi-word queries

    @Test("every word must match")
    func allWordsMustMatch() {
        let results = db.search("smiling face")
        #expect(!results.isEmpty)
        for emoji in results {
            #expect(emoji.searchBlob.contains("smiling"))
            #expect(emoji.searchBlob.contains("face"))
        }
    }

    @Test("nonsense queries return nothing")
    func nonsenseReturnsEmpty() {
        #expect(db.search("zzzxqq").isEmpty)
        #expect(db.search("").isEmpty)
        #expect(db.search("   ").isEmpty)
    }

    // MARK: - Canonical glyphs

    @Test("emoji-presentation glyphs drop the redundant VS16")
    func canonicalGlyphs() {
        // ✅ / 👍 default to color, so no U+FE0F — matches Apple's picker.
        #expect(db.search("checkmark").contains { $0.glyph == "✅" })
        #expect(db.all.first { $0.label == "thumbs up" }?.glyph == "👍")
        // 🗑️ / ✈️ default to text, so they KEEP the selector.
        #expect(db.all.first { $0.label == "wastebasket" }?.glyph == "🗑️")
        #expect(db.all.first { $0.label == "airplane" }?.glyph == "✈️")
    }

    // MARK: - Table integrity

    @Test("the table parsed a full emoji set")
    func tableLoaded() {
        #expect(db.all.count > 1_500)
    }

    @Test("no glyph newer than the OS floor leaks through")
    func versionCapped() {
        #expect(db.all.allSatisfy { $0.version <= EmojiDatabase.maxEmojiVersion })
    }

    @Test("orders are unique and contiguous")
    func ordersAreStable() {
        let orders = db.all.map(\.order)
        #expect(orders == Array(0..<db.all.count))
    }

    // MARK: - Categorized browsing

    @Test("Smileys & People is the first section and holds the faces")
    func smileysComeFirst() {
        let categories = db.categorized()
        #expect(categories.first?.category == .smileysAndPeople)
        // 😍 is an early smiley the e2e taps on the initial page.
        #expect(categories.first?.emoji.contains { $0.glyph == "😍" } == true)
    }

    @Test("categories are in canonical order with none empty")
    func categoriesOrdered() {
        let categories = db.categorized()
        let order = categories.map(\.category)
        #expect(order == EmojiCategory.allCases.filter { cat in
            order.contains(cat)
        })
        #expect(categories.allSatisfy { !$0.emoji.isEmpty })
        // Every surfaced emoji lands in exactly one category bucket.
        let bucketed = categories.reduce(0) { $0 + $1.emoji.count }
        #expect(bucketed == db.all.count)
    }
}
