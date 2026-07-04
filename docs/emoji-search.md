# Emoji search (`GallagerEmoji`)

The per-session emoji icon can be set from the Mac/iOS UI (a picker) or the CLI
(`gallager set-emoji` / `find-emoji`). Both resolve free-form text — `rocket`,
`trash`, `smiling face` — to a glyph through one shared, keyword-aware index:
the `GallagerEmoji` target.

## Why it exists

Search used to fail for anything but an emoji's single canonical name. The
Mac/iOS app used the third-party `SwiftEmojiPicker`, whose filter matched only a
one-word `searchKey`, and the CLI matched `Unicode.Scalar.Properties.name`.
Neither exposes synonyms, so searching **trash** found nothing even though 🗑️
exists — its Unicode name is `WASTEBASKET` (issue #630). `GallagerEmoji` replaces
both with a CLDR-derived keyword table, so "trash", "bin", "garbage", and "can"
all surface the wastebasket.

## Layout

```
ClaudeSpyPackage/Sources/GallagerEmoji/   # Foundation-only, no resources
├── Emoji.swift          # value type: glyph, label, keywords, group, version
├── EmojiCategory.swift  # the 8 picker sections (emojibase groups → categories)
├── EmojiDatabase.swift  # parse + version-cap + categorized() + search()
└── EmojiData.swift      # GENERATED tab-separated table (do not hand-edit)
```

- **`ClaudeSpyCommon/UI/GallagerEmojiPicker.swift`** — the SwiftUI picker
  (search field + category-jump grid) that replaced `SwiftEmojiPicker`. Presented
  by `DescriptionEditing.swift` as a macOS popover / iOS detent sheet.
- **`Gallager/EmojiNameLookup.swift`** — thin CLI adapter over `EmojiDatabase`.

The data is baked into Swift source (a `"""` string literal parsed at load),
**not** a resource bundle, because the `GallagerCLI` binary copied into
`Gallager.app/Contents/MacOS/` carries no `Bundle.module` alongside it.
(Xcode still links the shared `GallagerEmoji` target as a dynamic framework the
CLI reaches via an rpath added in the copy phase — see `docs/known-issues.md`;
don't swap the string literal for `.embedInCode` or a bundle, both are dead ends
documented there.)

## Search semantics

`EmojiDatabase.search(_:)` (see doc comments there):

1. An exact, case-insensitive match on the full label short-circuits to one
   result — so `set-emoji rocket` resolves 🚀 unambiguously.
2. Otherwise the query is tokenized on whitespace/hyphens and every word must
   **prefix** a word of some candidate's label or keywords. Prefix (not
   substring) matching keeps "bin" off "clim**bin**g" while still matching as you
   type ("roc" → 🚀).
3. Results rank name matches above keyword-synonym matches, then shorter/earlier
   labels first.

## Refreshing the emoji set

`EmojiData.swift` is generated from [`emojibase-data`][emojibase] (CLDR
annotations) by:

```
python3 scripts/generate-emoji-data.py
```

The script pins an `emojibase-data@<version>` tag for reproducibility, drops
component/regional-indicator entries, canonicalizes VS16 (✅ not ✅️, but keeps
🗑️), and applies a small **curated synonym overlay** (`EXTRA_KEYWORDS`) for gaps
CLDR misses — that's where "bin"/"rubbish" were added to the wastebasket. Add new
synonyms there and regenerate.

`EmojiDatabase.maxEmojiVersion` (currently 15.1) hides glyphs newer than the
deployment floor (macOS 15.0 / iOS 18.0) can render. Raise it when the floor
rises.

[emojibase]: https://github.com/milesj/emojibase
