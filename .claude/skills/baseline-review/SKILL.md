---
name: baseline-review
disable-model-invocation: true
allowed-tools:
  - Bash(./.claude/skills/baseline-review/scripts/compare-baselines.sh *)
  - Bash(rm -rf /tmp/baseline-review)
  - Read(/E2ETests/**/*.png)
  - Read(//tmp/baseline-review/**/*.png)
description: Review E2E baseline image changes in the current PR.
---

# E2E Baseline Image Review

Analyze all E2E baseline image changes in the current PR, compare them against `main`, and produce a report indicating whether each change is expected given the PR description.

## Overview

E2E baselines live in `E2ETests/<scenario-name>/##-<label>.png`. PRs that change UI behavior regenerate these screenshots. A typical PR with UI changes can touch 200+ baseline images, but most are just dithering/anti-aliasing artifacts from re-rendering. This skill separates the noise from real changes and verifies that real changes match the PR intent.

## Known Patterns

Before reviewing, be aware of these recurring patterns in baseline changes:

**Random pairing codes:** Images named `*-mac-code-generated.png` show the macOS pairing code screen. The 6-letter code is randomly generated each test run, so these images always differ between runs. This is expected and normal — not a rendering artifact, just non-deterministic test content. Classify these as "expected (non-deterministic content)."

**iOS paired/connected screens:** Images named `*-ios-paired.png` and `*-mac-connected.png` often have sub-pixel dithering differences. The script usually catches these as dithering, but if they show up as "changed" with very low diff percentages (<0.5%), they're almost certainly just rendering noise.

**Platform prefixes:** Baseline filenames always start with a platform prefix after the auto-numbered counter — `mac-` / `ios-` for standard scenarios, and `host-` / `viewer-` for two-Mac pairing scenarios (instance 0 = host, instance 1 = viewer). When grouping changes, treat `host-*` and `viewer-*` images from the same two-Mac scenario as separate views of the same feature; one side may legitimately change without the other.

## Workflow

### Step 1: Gather context

```bash
# Get PR description — this is the SOURCE OF TRUTH for what SHOULD have changed
gh pr view --json title,body,number

# Run the comparison script — generates diff images for all changed files
./.claude/skills/baseline-review/scripts/compare-baselines.sh
```

The script uses ImageMagick to compare every modified baseline against its `main` version and outputs:
- **new** — images that don't exist in main (new test scenarios)
- **deleted** — images removed from main
- **dithering** — images where <0.1% of pixels differ (effectively identical)
- **changed** — images with real pixel differences, with `diff_pct`, and paths to:
  - `diff_image` — red-highlighted overlay showing exactly which pixels changed
  - `main_image` — the original version from main

The script saves diff images and main extracts to `/tmp/baseline-review/`.

Parse the PR description and extract a clear list of **expected visual changes**. Be strict: only UI changes explicitly mentioned in the PR description count as "expected." Code-level changes visible in the diff but not called out in the PR summary do NOT count.

### Step 2: Visually inspect EVERY changed image

You must visually inspect every image the script reports as "changed." No spot-checking, no sampling — every single one. This is the core value of the review: catching the one unexpected change hiding among dozens of expected ones.

**For each changed image**, read these files:
1. The **current version** of the image (the file path from the `file` field)
2. The **diff image** (from `diff_image` field) — shows red highlights where pixels differ
3. If the diff image isn't clear enough, also read the **main version** (from `main_image` field)

For efficiency, batch reads: read 3-4 current images at once from the same scenario, then their diff images. This keeps context manageable while still checking everything.

For each image, record:
- What specifically changed (be precise: "tab bar appeared", "sidebar label lost :0 suffix", "terminal content scrolled 3 lines", etc.)
- Whether it matches an expected change from the PR description

### Step 3: Cross-reference with PR intent

For each real visual change, classify:

- **Expected** — the change directly maps to something the PR description says it changed
- **Expected (non-deterministic)** — known non-deterministic content like random pairing codes
- **Unexpected** — the change isn't mentioned in the PR description, even if code changes explain it

The key principle: **the PR description is the contract, not the code diff**. If the PR says "adds a tab bar to sessions" and a screenshot shows a new tab bar, that's expected. But if the same screenshot ALSO shows different terminal content or a shifted scroll position, that additional change is unexpected — even if code changes explain why.

Be strict. A change can be perfectly explained by the code and still be unexpected. The point of this review is to catch unintended visual side effects that the PR author may not have noticed.

### Step 4: Generate the HTML report (with screenshots) and open it

Produce a **self-contained HTML report with embedded screenshots** at
`docs/baseline-review-pr-<number>.html`, then open it in the browser. A picture of
the actual before/after is far more useful than prose — especially for unexpected
changes, where the reviewer needs to *see* the drift. Do NOT produce a `.md` file.

**4a. Pick the screenshots worth embedding.** Don't embed all 147 — embed where it adds value:
- **Every unexpected change** → an Old / New / Diff triptych (this is the whole point of the report).
- **One representative per expected change-group** → a New + Diff pair (the prose covers the rest; still list every file's name).
- **A handful of new-scenario renders** you opened to confirm the feature → New only.

**4b. Downscale the chosen images** into `/tmp/baseline-html/img/<key>.png`. Give each a short
`<key>` (e.g. `yolo10_old`, `yolo10_new`, `yolo10_diff`, `exp_sidebar_new`, `new_agents`).
The `main`/`diff` source paths come from the script's `main_image` / `diff_image` fields;
the `current` source is the `file` path. iOS baselines are ~2622px tall and trip a 2000px
image limit, so always downscale:

```bash
mkdir -p /tmp/baseline-html/img
magick "E2ETests/<scenario>/<file>.png"       -resize '820x760>' /tmp/baseline-html/img/<key>_new.png
magick "/tmp/baseline-review/main/<safe>.png"  -resize '820x760>' /tmp/baseline-html/img/<key>_old.png
magick "/tmp/baseline-review/diff/<safe>.png"  -resize '820x760>' /tmp/baseline-html/img/<key>_diff.png
```
(`<safe>` is the path with `E2ETests/` stripped and `/` → `_`, e.g. `yolo-mode-auto-approve_10-ios-...`.)

**4c. Write `docs/baseline-review-pr-<number>.html`** using the skeleton in
`references/report-template.html` (copy its `<style>`/lightbox JS verbatim — dark theme,
clickable zoom). Put images in with a token the inliner understands:

```html
<figure><img src="__DATAURI:yolo10_new__"><figcaption><span class="tag new">NEW</span> — $ 1 typed</figcaption></figure>
```

The report must contain the same sections as before — Summary table, the PR contract,
**Unexpected** (most prominent, with triptychs), **Expected** (grouped by change-type with a
representative figure, but **every changed file's name still listed**), New / Deleted tables,
and Non-deterministic / Noise / Dithering accounting. Every changed/new/deleted/dithering file
must still be accounted for somewhere.

**4d. Inline the screenshots and open it:**

```bash
python3 ./.claude/skills/baseline-review/scripts/inline-images.py docs/baseline-review-pr-<number>.html /tmp/baseline-html/img
open docs/baseline-review-pr-<number>.html
```

The inliner replaces every `__DATAURI:<key>__` with a base64 data URI from
`/tmp/baseline-html/img/<key>.png`, and **fails loudly if any image is missing** — so a green
run means no broken images. Finally, give the user a short text summary in chat (counts +
the unexpected findings) so they don't have to open the file to learn the verdict.

When grouping expected changes: describe the change type once with one representative figure,
but every single changed file must still appear by name in the report. No "and N more similar
files" — list them all.

### Step 5: Clean up

```bash
rm -rf /tmp/baseline-review /tmp/baseline-html
```
(Leave `docs/baseline-review-pr-<number>.html` in place — that's the deliverable.)

## Important Principles

- **Every image gets reviewed.** No spot-checking, no sampling. Read every changed image.
- **PR description is the contract** — not the code diff. Unexpected means "not in the PR description."
- **Be strict about unexpected changes.** When in doubt, mark it unexpected. False positives (flagging something that turns out to be fine) are much less costly than false negatives (missing a real issue).
- **Group by change type, not by scenario.** Multiple scenarios often show the same change. Describe the pattern once, list all affected files.
- **Every file appears in the report.** The report should account for every single changed, new, deleted, and dithering file. No file should be unaccounted for.
- **Unexpected changes may be real bugs.** This skill only flags them; it doesn't fix them. If the report surfaces unexpected changes that look like regressions, hand off to `fix-e2e-failures` (after CI re-runs) or use `e2e-manual-debugging` to inspect the live app and confirm what shifted.
