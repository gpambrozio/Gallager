---
name: baseline-review
disable-model-invocation: true
model: sonnet
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

### Step 4: Generate the report

Output the report directly to the user AND save it to `docs/baseline-review-pr-<number>.md`.

```markdown
## E2E Baseline Review: PR #<number> — <title>

### Expected Changes (from PR description)
- <Bulleted list of what the PR says it changes visually>

### New Images (N files)
<Which scenarios, whether expected>

### Deleted Images (N files)
<Which files, whether expected>

### Dithering Only (N files)
No meaningful visual differences — sub-pixel rendering artifacts only.

### Changed Images (N files)

#### Expected (non-deterministic content) — N files
Images that always differ between test runs due to random content (e.g., pairing codes).
<List files>

#### Expected Changes

##### ✅ `<scenario>/<filename>`
**What changed:** <precise description from visual inspection>
**Maps to:** <which PR description item this matches>

(Group images that show the exact same type of change under one heading,
but list every file explicitly — every image must appear in the report)

#### Unexpected Changes

##### ❌ `<scenario>/<filename>`
**What changed:** <precise description>
**Why unexpected:** <why this doesn't match the PR description>

### Summary
| Category | Count |
|----------|-------|
| New images | N |
| Deleted images | N |
| Dithering only | N |
| Non-deterministic content | N |
| Expected changes | N |
| **Unexpected changes** | **N** |
| **Total** | **N** |
```

When grouping expected changes: you can describe the change type once and list all files that share it, but every single changed file must appear explicitly in the report. No "and N more similar files" — list them all.

### Step 5: Clean up

```bash
rm -rf /tmp/baseline-review
```

## Important Principles

- **Every image gets reviewed.** No spot-checking, no sampling. Read every changed image.
- **PR description is the contract** — not the code diff. Unexpected means "not in the PR description."
- **Be strict about unexpected changes.** When in doubt, mark it unexpected. False positives (flagging something that turns out to be fine) are much less costly than false negatives (missing a real issue).
- **Group by change type, not by scenario.** Multiple scenarios often show the same change. Describe the pattern once, list all affected files.
- **Every file appears in the report.** The report should account for every single changed, new, deleted, and dithering file. No file should be unaccounted for.
