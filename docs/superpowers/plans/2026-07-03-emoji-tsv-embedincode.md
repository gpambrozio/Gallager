# Emoji Table as `emoji.tsv` via SPM `.embedInCode` Implementation Plan

> **ABANDONED (2026-07-03):** Tasks 1–2 were implemented and reviewed, then the
> approach was reverted during Task 3 verification — Xcode's macOS app build
> ignores `.embedInCode` when the resource target is shared between the app and
> the `GallagerCLI` executable product (falls back to a resource bundle +
> dynamic framework, which would also break the single-file CLI at runtime).
> See the spec's Outcome section. Only the
> generator's `KEYWORD_SEP` fix survived. Do not execute this plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the generated `EmojiData.swift` (117KB Swift string literal) with a committed `emoji.tsv` data file embedded into code at build time by SPM's `.embedInCode`, per `docs/superpowers/specs/2026-07-03-emoji-data-shipping-design.md`.

**Architecture:** The Python generator emits plain TSV to `ClaudeSpyPackage/Sources/GallagerEmoji/Resources/emoji.tsv`. SPM's `.embedInCode` resource rule generates `PackageResources.emoji_tsv: [UInt8]` (internal to the `GallagerEmoji` module) in DerivedData, so the bytes still compile into all three binaries — macOS app, iOS app, and the bare single-file `GallagerCLI`. `EmojiDatabase` decodes those bytes instead of reading `EmojiData.table`; runtime behavior is unchanged.

**Tech Stack:** Swift 6.3 / SPM (`.embedInCode`, tools-version ≥ 5.9), Python 3 generator, Swift Testing (`@Test`/`#expect`).

## Global Constraints

- Branch: `claude/issue-630` (PR #632). Commit incrementally; never `--no-verify`.
- The single-file `GallagerCLI` copied bare into `Gallager.app/Contents/MacOS/` MUST keep resolving `find-emoji trash` → `🗑️  wastebasket` (no resource bundle may be required).
- No new dependencies, no build-tool plugins — `.embedInCode` only.
- `EmojiDatabase.maxEmojiVersion` stays `15.1`; search semantics and all existing tests stay unchanged.
- Comment lines in the TSV are `"# "`-prefixed (hash-space). Bare-`#` prefix is NOT a comment marker: the keycap emoji `#️⃣` row starts with `#` + VS16.
- When executing builds/tests in a Claude session, route through the XcodeBuildTools skills (`swift-package`, `xcodebuild`); the commands below are what those skills should run.

---

### Task 1: Generator emits `emoji.tsv` (and fixes the `|`-escaping review bug)

**Files:**
- Modify: `scripts/generate-emoji-data.py`
- Create (generated): `ClaudeSpyPackage/Sources/GallagerEmoji/Resources/emoji.tsv`

**Interfaces:**
- Consumes: emojibase-data 16.0.3 (pinned URL already in the script).
- Produces: `Resources/emoji.tsv` — 4 header lines starting `"# "`, then one row per emoji: `glyph<TAB>label<TAB>kw|kw|…<TAB>group<TAB>version` (exactly 5 tab-separated fields, version like `1.0`). No backslash escaping (raw bytes). No keyword may contain `\t`, `\n`, or `|`. Task 2's parser consumes this format verbatim.

- [ ] **Step 1: Rewrite the script's output side**

Change the docstring (lines 1–21) to describe the new output:

```python
#!/usr/bin/env python3
"""Generate ``Resources/emoji.tsv`` for the ``GallagerEmoji`` target.

The Mac/iOS emoji picker and the ``gallager find-emoji`` / ``set-emoji`` CLI
commands both need to resolve an emoji from a free-form query like ``trash``,
``bin``, or ``garbage``. Foundation only exposes an emoji's *formal* Unicode
name (``WASTEBASKET`` for 🗑️), which is why searching for "trash" used to find
nothing. This script pulls the CLDR-derived keyword annotations from
`emojibase-data` into a compact tab-separated table. SPM's ``.embedInCode``
resource rule compiles the bytes into every binary that links ``GallagerEmoji``
(no runtime resource bundle, so the single-file ``GallagerCLI`` copied into the
app bundle stays self-contained).

Run it whenever you want to refresh the emoji set:

    python3 scripts/generate-emoji-data.py

It rewrites ``ClaudeSpyPackage/Sources/GallagerEmoji/Resources/emoji.tsv`` in
place. The output is deterministic (sorted by group then CLDR display order) so
re-running with the same upstream data produces no diff.
"""
```

Change `OUTPUT_PATH`:

```python
OUTPUT_PATH = os.path.join(
    REPO_ROOT,
    "ClaudeSpyPackage",
    "Sources",
    "GallagerEmoji",
    "Resources",
    "emoji.tsv",
)
```

Add a shared keyword guard right after the `VS16` constant (this is the review-comment fix — `KEYWORD_SEP` was previously not excluded, so CLDR's `:|` emoticon corrupted the keyword field):

```python
def usable_keyword(text: str) -> bool:
    """Keywords must not collide with the TSV field or keyword separators.

    ``KEYWORD_SEP`` matters too (PR #632 review): the neutral-face emoticon
    ``:|`` would otherwise land verbatim in the ``|``-joined keyword field and
    silently parse as the keyword ``:``.
    """
    return bool(text) and FIELD_SEP not in text and "\n" not in text and KEYWORD_SEP not in text
```

In `normalize()`, replace the three inline conditions with the helper:

```python
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
```

Extend the row assertions with the comment-marker guard:

```python
        assert FIELD_SEP not in glyph and "\n" not in glyph, glyph
        assert FIELD_SEP not in label and "\n" not in label, label
        assert KEYWORD_SEP not in glyph, glyph
        # "# " (hash-space) opens a comment line in the TSV. #️⃣ starts with a
        # bare '#' + VS16, which is fine — but a glyph starting "# " would be
        # swallowed by EmojiDatabase's comment skip.
        assert not glyph.startswith("# "), glyph
```

Replace `render()` entirely (the Swift wrapper and the backslash doubling both die — the table is no longer inside a Swift `"""` literal, so `\` needs no escaping):

```python
def render(rows: list[tuple]) -> str:
    lines = [
        "# Generated by scripts/generate-emoji-data.py — DO NOT EDIT BY HAND.",
        "# Source: emojibase-data (CLDR annotations). Tab-separated fields:",
        "#   glyph <TAB> label <TAB> keyword|keyword|… <TAB> group <TAB> version",
        f"# {len(rows)} emoji. Lines starting with '# ' are comments (see EmojiDatabase.parse).",
    ]
    for group, _order, glyph, label, tags, version in rows:
        keywords = KEYWORD_SEP.join(tags)
        # version kept as a Double-parseable token.
        version_str = repr(float(version))
        lines.append(FIELD_SEP.join([glyph, label, keywords, str(group), version_str]))
    return "\n".join(lines) + "\n"
```

Replace `main()` (creates the new directory on first run):

```python
def main() -> None:
    rows = normalize(fetch())
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(render(rows))
    print(f"Wrote {len(rows)} emoji to {OUTPUT_PATH}", file=sys.stderr)
```

- [ ] **Step 2: Run the generator**

Run: `python3 scripts/generate-emoji-data.py`
Expected stderr: `Fetching https://raw.githubusercontent.com/...` then `Wrote 1906 emoji to .../ClaudeSpyPackage/Sources/GallagerEmoji/Resources/emoji.tsv`

(Do NOT delete `EmojiData.swift` yet — the Swift side still references it until Task 2.)

- [ ] **Step 3: Verify the TSV shape**

```bash
cd ClaudeSpyPackage/Sources/GallagerEmoji/Resources
head -4 emoji.tsv                                   # 4 "# " comment lines
awk -F'\t' 'NF != 5 && !/^# /' emoji.tsv | wc -l    # expect 0 (only comments are non-5-field)
grep -c '' emoji.tsv                                # expect 1910 (1906 rows + 4 comments)
grep $'\t''keycap: #'$'\t' emoji.tsv                # keycap row present, starts with #️⃣
awk -F'\t' '$3 ~ /(^|[|]):[|]/ {print}' emoji.tsv | wc -l   # expect 0 — no ":|"-corrupted keyword survives
```

Also spot-check the wastebasket row still carries the issue-#630 synonyms:

```bash
grep $'\t'wastebasket$'\t' emoji.tsv
```
Expected: one row containing `trash`, `bin`, `garbage`, `can`, `rubbish` in the keyword field.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-emoji-data.py ClaudeSpyPackage/Sources/GallagerEmoji/Resources/emoji.tsv
git commit -m "Generator emits emoji.tsv (raw TSV) and excludes KEYWORD_SEP from keywords"
```

---

### Task 2: `EmojiDatabase` reads the embedded resource; delete `EmojiData.swift`

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` (GallagerEmoji target, ~line 314)
- Modify: `ClaudeSpyPackage/Sources/GallagerEmoji/EmojiDatabase.swift`
- Modify: `ClaudeSpyPackage/Sources/GallagerEmoji/Emoji.swift` (doc comment only)
- Delete: `ClaudeSpyPackage/Sources/GallagerEmoji/EmojiData.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerEmojiTests/EmojiDatabaseTests.swift`

**Interfaces:**
- Consumes: `Resources/emoji.tsv` from Task 1; SPM-generated `PackageResources.emoji_tsv: [UInt8]` (internal to the module, name = filename with non-identifier chars mapped to `_`).
- Produces: `EmojiDatabase.init(maxVersion:)` unchanged publicly; new **internal** `EmojiDatabase.init(table: String, maxVersion: Double)` used by tests.

- [ ] **Step 1: Write the failing tests**

Append to `EmojiDatabaseTests.swift` inside the struct:

```swift
    // MARK: - TSV comment handling (data ships as emoji.tsv, embedded in code)

    @Test("\"# \"-prefixed comment lines are skipped even when they look like rows")
    func commentLinesSkipped() {
        let table = """
        # Generated by scripts/generate-emoji-data.py — DO NOT EDIT BY HAND.
        # 😀\tnot an emoji\t\t0\t1.0
        😀\tgrinning face\thappy\t0\t1.0
        #️⃣\tkeycap: #\thash|keycap|pound\t8\t0.6
        """
        let db = EmojiDatabase(table: table, maxVersion: 15.1)
        #expect(db.all.map(\.glyph) == ["😀", "#️⃣"])
    }

    @Test("keycap # ships in the embedded table (comment skip must not eat it)")
    func keycapHashSurvives() {
        #expect(db.all.contains { $0.label == "keycap: #" })
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cd ClaudeSpyPackage && swift test --filter GallagerEmojiTests`
Expected: **compile error** — `EmojiDatabase` has no `init(table:maxVersion:)`. (First run builds the whole test product; this is slow once, then cached.)

- [ ] **Step 3: Split the init and add the comment skip (still reading `EmojiData.table`)**

In `EmojiDatabase.swift`, replace the existing `public init`:

```swift
    public init(maxVersion: Double = EmojiDatabase.maxEmojiVersion) {
        self.init(table: EmojiData.table, maxVersion: maxVersion)
    }

    /// Internal so tests can feed a hand-built table.
    init(table: String, maxVersion: Double) {
        self.all = Self.parse(table, maxVersion: maxVersion)
    }
```

In `parse`, add the comment skip as the first statement of the loop body:

```swift
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
            // Comment lines start with "# " (hash-space). A bare '#' prefix is
            // NOT a comment: the keycap emoji #️⃣ opens its row with '#' + VS16.
            if line.hasPrefix("# ") { continue }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ClaudeSpyPackage && swift test --filter GallagerEmojiTests`
Expected: all tests pass, 0 failures (the two new tests included).

- [ ] **Step 5: Wire `.embedInCode` and swap the data source**

`Package.swift` — the `GallagerEmoji` target becomes:

```swift
    // Foundation-only emoji table + keyword search (issue #630). Shared by the
    // picker UI and the CLI so "trash" → 🗑️ everywhere. Data is generated by
    // scripts/generate-emoji-data.py into Resources/emoji.tsv; .embedInCode
    // compiles the bytes into every linking binary (PackageResources.emoji_tsv),
    // so the single-file GallagerCLI needs no resource bundle.
    .target(
        name: "GallagerEmoji",
        resources: [
            .embedInCode("Resources/emoji.tsv"),
        ]
    ),
```

`EmojiDatabase.swift` — point the public init at the embedded bytes:

```swift
    public init(maxVersion: Double = EmojiDatabase.maxEmojiVersion) {
        self.init(
            table: String(decoding: PackageResources.emoji_tsv, as: UTF8.self),
            maxVersion: maxVersion
        )
    }
```

Update the struct's doc comment first paragraph to match:

```swift
/// The parsed, searchable emoji table shared by the picker UI and the CLI.
///
/// The data lives in `Resources/emoji.tsv` and is embedded into code at build
/// time by SPM's `.embedInCode` (`PackageResources.emoji_tsv`), so the bytes
/// travel inside every linking binary — including the bare single-file
/// `GallagerCLI`. Parsing the ~1900-row table is done once and cached on
/// ``shared``. Search matches against each emoji's label *and* its CLDR
/// keyword synonyms, which is what lets "trash" resolve 🗑️ where the old
/// Unicode-name lookup (`WASTEBASKET`) could not.
```

In `Emoji.swift`, update the first doc-comment line that references the deleted type:

```swift
/// A single searchable emoji, backed by the CLDR annotation table
/// (`Resources/emoji.tsv`) embedded into the binary at build time.
```

Delete the generated file:

```bash
git rm ClaudeSpyPackage/Sources/GallagerEmoji/EmojiData.swift
```

- [ ] **Step 6: Run the full emoji suite against the embedded data**

Run: `cd ClaudeSpyPackage && swift test --filter GallagerEmojiTests`
Expected: all tests pass, 0 failures — `tableLoaded` (count > 1500), `keycapHashSurvives`, and the trash/bin/garbage synonym tests now execute against bytes decoded from `PackageResources.emoji_tsv`.

If the build fails with `cannot find 'PackageResources' in scope`, the mangled accessor name differs — inspect what SPM generated:

```bash
find "$SANDBOX_DERIVED_DATA" .build -name "*.swift" -path "*DerivedSources*" 2>/dev/null | xargs grep -l "PackageResources" | head -1 | xargs sed -n '1,5p'
```

and adjust the property name in `init` to match.

- [ ] **Step 7: Commit**

```bash
git add -A ClaudeSpyPackage
git commit -m "Ship emoji table as embedInCode resource instead of generated Swift"
```

---

### Task 3: Docs, PR description, and end-to-end bundle verification

**Files:**
- Modify: `docs/emoji-search.md`
- Modify: `CLAUDE.md` (the Emoji search reference line)
- Verify: built `Gallager.app` bundle

**Interfaces:**
- Consumes: Tasks 1–2 landed; scheme names `ClaudeSpyServer` (macOS) / `ClaudeSpy` (iOS).
- Produces: docs consistent with the shipped mechanism; PR #632 description updated; proof the embedded CLI still resolves keywords.

- [ ] **Step 1: Update `docs/emoji-search.md`**

Layout block — replace the `EmojiData.swift` line so the tree reads:

```
ClaudeSpyPackage/Sources/GallagerEmoji/
├── Emoji.swift            # value type: glyph, label, keywords, group, version
├── EmojiCategory.swift    # the 8 picker sections (emojibase groups → categories)
├── EmojiDatabase.swift    # parse + version-cap + categorized() + search()
└── Resources/emoji.tsv    # GENERATED data table (do not hand-edit)
```

Replace the "baked into Swift source" paragraph (currently lines 33–35) with:

```markdown
The data ships as `Resources/emoji.tsv`, embedded **into code** at build time by
SPM's `.embedInCode` resource rule (`PackageResources.emoji_tsv: [UInt8]`) —
**not** a runtime resource bundle, because the single-file `GallagerCLI` binary
copied into `Gallager.app/Contents/MacOS/` wouldn't carry a `Bundle.module`
alongside it. Lines starting with `# ` (hash-space) are comments; a bare `#`
can open a real row (`#️⃣`).
```

In "Refreshing the emoji set", change the intro sentence to:

```markdown
`Resources/emoji.tsv` is generated from [`emojibase-data`][emojibase] (CLDR
annotations) by:
```

- [ ] **Step 2: Update the CLAUDE.md pointer**

In the Reference Docs list, in the `**Emoji search:**` line, replace

`Data is generated by \`scripts/generate-emoji-data.py\` from CLDR annotations into \`EmojiData.swift\`;`

with

`Data is generated by \`scripts/generate-emoji-data.py\` from CLDR annotations into \`Sources/GallagerEmoji/Resources/emoji.tsv\` (embedded into code at build time via SPM \`.embedInCode\`, so the single-file CLI still carries it);`

- [ ] **Step 3: Build both apps (proves Xcode's SPM integration handles `.embedInCode`)**

Run (via the `xcodebuild` skill):

```bash
xcodebuild -project ClaudeSpy.xcodeproj -scheme ClaudeSpyServer -configuration Debug build
xcodebuild -project ClaudeSpy.xcodeproj -scheme ClaudeSpy -destination 'generic/platform=iOS Simulator' build
```

Expected: both succeed, 0 errors.

- [ ] **Step 4: Verify the embedded CLI still resolves keywords (the load-bearing constraint)**

```bash
APP=$(find "$SANDBOX_DERIVED_DATA" -name "Gallager.app" -path "*Debug*" -not -path "*Index*" | head -1)
"$APP/Contents/MacOS/GallagerCLI" find-emoji trash
"$APP/Contents/MacOS/GallagerCLI" find-emoji bin
```

Expected: first line of each output is `🗑️  wastebasket`, exit 0. This is the single-file constraint from the spec, re-proven on the new mechanism.

- [ ] **Step 5: Commit docs**

```bash
git add docs/emoji-search.md CLAUDE.md
git commit -m "Docs: emoji table ships as emoji.tsv via embedInCode"
```

- [ ] **Step 6: Update the PR description and push**

In PR #632's body (`gh pr view 632 --json body`), replace the sentence in the **Fix** section's first bullet:

> is generated by `scripts/generate-emoji-data.py` from [emojibase-data](https://github.com/milesj/emojibase)'s CLDR annotations into a compact tab-separated table **baked into Swift source** — not a resource bundle, because the single-file `GallagerCLI` copied into `Gallager.app/Contents/MacOS/` wouldn't carry a `Bundle.module` alongside it.

with:

> is generated by `scripts/generate-emoji-data.py` from [emojibase-data](https://github.com/milesj/emojibase)'s CLDR annotations into a committed `Resources/emoji.tsv`, **embedded into code at build time** by SPM's `.embedInCode` (so it still travels inside the single-file `GallagerCLI` copied into `Gallager.app/Contents/MacOS/` — no resource bundle needed).

Apply with `gh pr edit 632 --body-file <updated-body.md>` (write the full updated body to a temp file in the scratchpad first — do not lose the rest of the description).

Then push:

```bash
git push
```

---

## Self-Review Notes

- Spec coverage: data file + header (Task 1), package wiring/parser/deletion (Task 2), generator + `|` fix (Task 1 Step 1), verification trio and docs/PR scope (Task 3). The spec's "three minor review comments are out of scope" — respected; only the `|` escaping fix rides along, as specified.
- The `#️⃣` collision and the dropped backslash-doubling are handled explicitly (Task 1 Step 1, Task 2 Step 3) — both were silent-corruption risks the spec's "`#`-prefixed header" wording didn't anticipate; the spec's intent (comment header) is preserved via the `"# "` rule.
- Type consistency: `EmojiDatabase.init(table:maxVersion:)` internal, used only by tests; `PackageResources.emoji_tsv` referenced in exactly one place with a name-discovery fallback.
