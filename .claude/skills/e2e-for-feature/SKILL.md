---
name: e2e-for-feature
allowed-tools:
  - Bash(./scripts/e2e-test.sh *)
  - Bash(git diff *)
  - Bash(git log *)
  - Bash(rm -rf E2ETests/*)
description: >-
  Automatically create E2E test scenarios that prove a new feature works. Use this skill when a PR
  or branch introduces a new feature and you want to generate an end-to-end scenario that exercises
  it, takes screenshots at key points, and verifies the screenshots show the expected behavior.
  Trigger when: the user says "create e2e for this feature", "write an e2e test for this PR",
  "prove this feature works with e2e", "add e2e coverage for this change", or any variation of
  wanting automated E2E proof that new code works. Also use when the user asks to "test this feature
  end to end" or "create a scenario for the new feature". Do NOT use for fixing existing failing
  scenarios (use e2e-testing), manual debugging (use e2e-manual-debugging), or reviewing baselines
  (use baseline-review).
---

# E2E Scenario Creation for New Features

This skill automates the full workflow of creating an E2E test scenario that proves a new feature works: analyze the PR, write the scenario, run it until it passes, and verify screenshots show expected content.

## Prerequisites

Before starting, load the E2E testing reference material. Read these files from the existing e2e-testing skill:
- `.claude/skills/e2e-testing/references/test-steps-reference.md` — all TestStep signatures
- `.claude/skills/e2e-testing/references/patterns.md` — common scenario patterns
- `.claude/skills/e2e-testing/references/element-queries.md` — ElementQuery matching

Also read `docs/e2e-testing.md` in the project root for screenshot comparison details.

## Workflow

### Phase 1: Understand what the PR implements

Run `git diff main...HEAD --stat` and `git log main..HEAD --oneline` to see what changed.

Then read the key changed files to understand:
- **What new UI elements were added?** (buttons, views, screens, settings)
- **What user-facing behavior changed?** (new flows, new states, new interactions)
- **Which platforms are affected?** (iOS only, macOS only, or both)
- **Are there new accessibility hooks?** (`.accessibilityLabel`, `.help()`, `.accessibilityIdentifier`)

Think about what a user would do to exercise this feature end-to-end. The scenario should simulate that user journey.

### Phase 2: Design the scenario

Based on the PR analysis, decide:

1. **What setup is needed?** Pick the right foundation:
   - Feature needs both iOS + macOS paired → compose with `FreshPairingScenario.scenario`
   - Feature is macOS-only → use `Shortcut.macOnlySetup`
   - Feature needs two Mac instances → use `Shortcut.twoMacPairing`
   - Feature needs a tmux session → add `tmuxCreateSession` + pane selection steps

2. **What steps exercise the feature?** Map the user journey to TestStep calls. The scenario should follow the natural flow a user would take to use the feature.

3. **Where should screenshots go?** Place screenshots at moments that prove the feature works:
   - After the feature's UI first appears
   - After key interactions with the feature
   - After the feature completes its primary purpose
   - On both platforms if the feature spans iOS and macOS

### Phase 3: Write the scenario

Create the scenario file in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/`.

#### Mandatory rules

- **All screenshots must use `compare: true`** — this is the default, so simply omit the `compare` parameter. Never pass `compare: false`. If a screenshot would be unreliable, fix the root cause instead of skipping comparison.
- **Screenshot labels must start with a platform prefix:** `ios-`, `mac-`, `host-`, or `viewer-`
- **Use `public enum` with a `public static let scenario`** property
- **Use `ClaudeSpyE2ELib.scenario(...)` factory** with descriptive name and relevant tags
- **No cleanup steps** — the orchestrator handles cleanup automatically
- **No manual number prefixes in labels** — auto-numbered by the framework
- **Use existing Shortcuts** — don't duplicate setup steps that shortcuts already provide
- **Add numbered phase comments** — group steps into logical phases with `// 1. Description`
- **Use `wait(seconds:)` after actions** — UI transitions need time (0.5-3 seconds typical)

#### Adding accessibility hooks

If the new feature's UI elements aren't discoverable by ElementQuery, add accessibility modifiers to the app code:

**iOS (SwiftUI):**
```swift
.accessibilityLabel("Feature Label")      // → ElementQuery.label("Feature Label")
.accessibilityIdentifier("feature-id")    // → ElementQuery.identifier("feature-id")
```

**macOS toolbar buttons:**
```swift
.help("Feature Action")                   // → macClickButton(titled: "Feature Action")
```

**macOS sidebar/list rows:** Must use `Button` (not `onTapGesture`) with `.accessibilityLabel()` on the Button. Use `macCGClick(titled:)` for list selection, `macClickButton(titled:)` for disclosure toggles.

#### Register the scenario

Add it to the **end** of the `allScenarios` array in `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift`.

### Phase 4: Build and run

Run the scenario:

```bash
./scripts/e2e-test.sh --scenario "Scenario Name"
```

If it fails:
1. Read the error output carefully
2. Determine if the fix belongs in the scenario (wrong query, missing wait, wrong element) or in app code (missing accessibility hook, timing issue)
3. Fix the issue
4. Delete any stale baselines: `rm -rf E2ETests/<scenario-dir>/`
5. Re-run until it passes

Common fixes:
- **Element not found** → add `iosLogUI` before the failing step, run again, read the accessibility tree to find the correct query
- **Screenshot mismatch** → delete the baseline and re-run to regenerate
- **Timing issue** → add or increase `wait(seconds:)` before the step
- **macOS button not found** → check if the element uses `.help()` vs `.accessibilityLabel()` vs title

### Phase 5: Verify screenshots (critical)

After the scenario passes, verify every screenshot baseline visually. Do not just check pass/fail status.

For each screenshot in `E2ETests/<scenario-name>/`:
1. Read the PNG file
2. Confirm it shows the expected content for that point in the scenario
3. Check that the new feature is actually visible and working in the screenshot

If a screenshot shows wrong content (blank area, missing element, wrong state):
- The baseline was created from a broken state
- Delete it: `rm E2ETests/<scenario-name>/<screenshot>.png`
- Fix the timing or steps
- Re-run to regenerate

### Phase 6: Confirm consistency

Run the scenario at least 2 more times (3 total) to confirm it passes consistently.

Save screenshots from each run for review:
```bash
mkdir -p e2e-review-runs/run1 e2e-review-runs/run2 e2e-review-runs/run3
cp E2ETests/<scenario-name>/*.png e2e-review-runs/run1/  # after run 1
# ... run again, copy to run2, run3
```

Compare screenshots across runs — they should be consistent. If a screenshot differs between runs, investigate the flakiness source (animation timing, async content loading, etc.) and fix it before finalizing.

### Phase 7: Report results

After all runs pass with verified screenshots, summarize:
- What the scenario tests (the user journey it simulates)
- How many screenshots it takes and what each one proves
- Any app code changes made (accessibility hooks, etc.)
- Files created/modified

## Example: Feature adds a "Favorite Sessions" button on iOS

```
Phase 1: PR adds a star button on session rows, persists favorites, shows a "Favorites" filter.

Phase 2: Design
- Needs full pairing (iOS + macOS) → compose FreshPairingScenario
- Create tmux session so there's something to favorite
- Steps: connect to session, tap star, go back, tap Favorites filter, verify filtered list
- Screenshots: session with star button, favorites filter active

Phase 3: Write FavoriteSessionsScenario.swift

Phase 4-6: Run 3 times, verify screenshots show star button and filtered list
```

## What this skill does NOT do

- Fix existing failing scenarios → use `e2e-testing` skill
- Manual interactive debugging → use `e2e-manual-debugging` skill
- Review or compare baselines → use `baseline-review` skill
- Write unit tests → this is specifically for E2E scenarios
