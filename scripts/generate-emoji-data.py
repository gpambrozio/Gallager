#!/usr/bin/env python3
"""Generate ``EmojiData.swift`` for the ``GallagerEmoji`` target.

The Mac/iOS emoji picker and the ``gallager find-emoji`` / ``set-emoji`` CLI
commands both need to resolve an emoji from a free-form query like ``trash``,
``bin``, or ``garbage``. Foundation only exposes an emoji's *formal* Unicode
name (``WASTEBASKET`` for 🗑️), which is why searching for "trash" used to find
nothing. This script pulls the CLDR-derived keyword annotations from
`emojibase-data` and bakes them into a compact tab-separated table that is
embedded directly in the ``GallagerEmoji`` binary (no runtime resource bundle,
so the single-file ``GallagerCLI`` copied into the app bundle stays
self-contained).

Run it whenever you want to refresh the emoji set:

    python3 scripts/generate-emoji-data.py

It rewrites ``ClaudeSpyPackage/Sources/GallagerEmoji/EmojiData.swift`` in place.
The output is deterministic (sorted by group then CLDR display order) so
re-running with the same upstream data produces no diff.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request

# Pinned tag so regeneration is reproducible rather than tracking a moving
# `master`. Bump deliberately when refreshing the emoji set.
EMOJIBASE_URL = (
    "https://raw.githubusercontent.com/milesj/emojibase/"
    "emojibase-data@16.0.3/packages/data/en/data.raw.json"
)

# emojibase `group` numbers. 2 (Component: skin-tone / hair modifiers) is
# dropped — those are not standalone pickable emoji. Entries with no group
# (the bare regional-indicator letters A–Z) are dropped for the same reason.
COMPONENT_GROUP = 2

# Curated synonyms CLDR's English annotations miss, keyed by emojibase label.
# This is the extension point for issue #630's "I'm sure this is not the only
# example" — CLDR has no "bin" for the wastebasket, so searching "bin" found
# nothing. Add sensible aliases here (lowercase) and regenerate.
EXTRA_KEYWORDS = {
    "wastebasket": ["bin", "rubbish", "dustbin", "trashcan", "trash can", "recycle", "delete"],
    "litter in bin sign": ["trash", "garbage", "rubbish"],
    "recycling symbol": ["recycle", "reuse", "green"],
    "skull": ["dead", "death"],
    "skull and crossbones": ["dead", "death", "poison", "danger"],
    "money bag": ["cash", "dollars"],
    "party popper": ["celebrate", "celebration", "congrats", "congratulations"],
    "sparkles": ["shiny", "clean", "magic"],
    "thumbs up": ["approve", "like", "yes", "ok", "lgtm"],
    "thumbs down": ["disapprove", "dislike", "no"],
    "check mark button": ["done", "complete", "completed", "pass", "success"],
    "cross mark": ["fail", "failed", "error", "wrong", "no"],
    "hammer and wrench": ["tools", "build", "fix"],
    "gear": ["settings", "config", "cog", "options"],
    "magnifying glass tilted left": ["search", "find", "zoom"],
    "magnifying glass tilted right": ["search", "find", "zoom"],
    "bug": ["defect", "issue", "insect"],
    "rocket": ["launch", "ship", "deploy", "fast"],
    "fire": ["hot", "flame", "lit"],
    "light bulb": ["idea", "bright"],
    "locked": ["secure", "private", "security"],
    "unlocked": ["insecure", "open"],
    "warning": ["caution", "alert", "danger"],
    "package": ["box", "parcel", "shipping", "delivery"],
    "memo": ["note", "notes", "write", "document", "todo"],
    "pushpin": ["pin", "location"],
    "chart increasing": ["growth", "up", "trending", "profit"],
    "chart decreasing": ["loss", "down", "trending", "decline"],
    "hourglass done": ["wait", "waiting", "time", "loading"],
    "hourglass not done": ["wait", "waiting", "time", "loading"],
}

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_PATH = os.path.join(
    REPO_ROOT,
    "ClaudeSpyPackage",
    "Sources",
    "GallagerEmoji",
    "EmojiData.swift",
)

FIELD_SEP = "\t"
KEYWORD_SEP = "|"


VS16 = "️"


def usable_keyword(text: str) -> bool:
    """Keywords must not collide with the table's field or keyword separators.

    ``KEYWORD_SEP`` matters too (PR #632 review): the neutral-face emoticon
    ``:|`` would otherwise land verbatim in the ``|``-joined keyword field and
    silently parse as the keyword ``:``.
    """
    return bool(text) and FIELD_SEP not in text and "\n" not in text and KEYWORD_SEP not in text


def canonical_glyph(entry: dict) -> str:
    """Return the canonical renderable glyph.

    emojibase appends VS16 to its ``emoji`` field even for scalars that already
    default to color presentation (✅️, 👍️). Apple's picker — and the old CLI's
    `scalar.isEmojiPresentation` logic — use the bare form (✅, 👍). We match
    that: for a single-scalar emoji, append VS16 only when it defaults to *text*
    presentation (``type == 0``, e.g. 🗑️, ✈️, ❤️). Multi-scalar sequences (ZWJ,
    flags, keycaps) carry their own required selectors, so use them verbatim.
    """
    hexcode = entry["hexcode"]
    if "-" in hexcode:
        return entry["emoji"]
    base = chr(int(hexcode, 16))
    # type: 1 = emoji presentation by default, 0 = text presentation by default.
    return base if entry.get("type", 1) == 1 else base + VS16


def fetch() -> list[dict]:
    print(f"Fetching {EMOJIBASE_URL}", file=sys.stderr)
    with urllib.request.urlopen(EMOJIBASE_URL, timeout=60) as resp:
        return json.load(resp)


def normalize(entries: list[dict]) -> list[tuple]:
    rows: list[tuple] = []
    for entry in entries:
        group = entry.get("group")
        if group is None or group == COMPONENT_GROUP:
            continue
        glyph = canonical_glyph(entry)
        label = entry["label"].strip()
        order = entry.get("order", 0)
        version = entry.get("version", 0)
        # Keywords: CLDR annotation tags plus any words in the label. Store the
        # tags verbatim (some are multi-word, e.g. "red heart"); the label is
        # folded into the search blob at runtime so we don't duplicate it here.
        tags = []
        seen = set()
        for tag in entry.get("tags", []) or []:
            tag = tag.strip().lower()
            if tag not in seen and usable_keyword(tag):
                seen.add(tag)
                tags.append(tag)
        # emoticons (":)" etc.) make handy extra search keys.
        emoticons = entry.get("emoticon")
        if isinstance(emoticons, str):
            emoticons = [emoticons]
        for emo in emoticons or []:
            emo = emo.strip()
            if emo not in seen and usable_keyword(emo):
                seen.add(emo)
                tags.append(emo)

        # Curated synonyms CLDR misses (see EXTRA_KEYWORDS).
        for extra in EXTRA_KEYWORDS.get(label.lower(), []):
            extra = extra.strip().lower()
            if extra not in seen and usable_keyword(extra):
                seen.add(extra)
                tags.append(extra)

        assert FIELD_SEP not in glyph and "\n" not in glyph, glyph
        assert FIELD_SEP not in label and "\n" not in label, label
        assert KEYWORD_SEP not in glyph, glyph
        rows.append((group, order, glyph, label, tags, version))

    # Sort by (group, CLDR order) so the array's natural order is display order.
    rows.sort(key=lambda r: (r[0], r[1]))
    return rows


def render(rows: list[tuple]) -> str:
    lines = []
    for group, _order, glyph, label, tags, version in rows:
        keywords = KEYWORD_SEP.join(tags)
        # version kept as a Double-parseable token.
        version_str = repr(float(version))
        row = FIELD_SEP.join([glyph, label, keywords, str(group), version_str])
        # The table is emitted as a Swift `"""` literal, so a lone backslash
        # (from emoticons like \m/ or :\) would be read as an escape. Double it
        # so the runtime string keeps the literal backslash.
        row = row.replace("\\", "\\\\")
        lines.append(row)
    table = "\n".join(lines)

    header = f'''// swiftformat:disable all
// swiftlint:disable all
// Generated by scripts/generate-emoji-data.py — DO NOT EDIT BY HAND.
//
// Source: emojibase-data (CLDR annotations). Each row is tab-separated:
//   glyph <TAB> label <TAB> keyword|keyword|… <TAB> group <TAB> version
// `group` is the emojibase category number; `version` is the Unicode emoji
// version used to hide glyphs newer than the running OS can render.
//
// {len(rows)} emoji.

enum EmojiData {{
    /// Tab-separated emoji table, parsed once by `EmojiDatabase`.
    static let table = """
{table}
"""
}}
// swiftlint:enable all
// swiftformat:enable all
'''
    return header


def main() -> None:
    rows = normalize(fetch())
    swift = render(rows)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(swift)
    print(f"Wrote {len(rows)} emoji to {OUTPUT_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()
