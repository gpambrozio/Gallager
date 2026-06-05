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

This skill automates the full workflow of creating an E2E test scenario that proves a new feature works: analyze the PR, write the scenario, run it until it passes, and verify screenshots show the expected content.

## Prerequisites

Before starting, load the E2E testing reference material. Read these files from the existing e2e-testing skill:
- `.claude/skills/e2e-testing/references/test-steps-reference.md` — all TestStep signatures (including the `instance:` parameter on every macOS step, hook events, scripts, file/clipboard helpers, version-compatibility steps)
- `.claude/skills/e2e-testing/references/patterns.md` — common scenario patterns (multi-instance, hook events, script injection, terminal content assertions, version mismatch, …)
- `.claude/skills/e2e-testing/references/element-queries.md` — ElementQuery matching, including `.help` and `.anyTextMatches`

Also read `docs/e2e-testing.md` in the project root for screenshot comparison and failure-screenshot details.

## Workflow

### Phase 1: Understand what the PR implements

Run `git diff main...HEAD --stat` and `git log main..HEAD --oneline` to see what changed.

Then read the key changed files to understand:
- **What new UI elements were added?** (buttons, views, screens, settings)
- **What user-facing behavior changed?** (new flows, new states, new interactions)
- **Which platforms/instances are affected?** (iOS, macOS host, macOS viewer, two-Mac, server)
- **Are there new accessibility hooks?** (`.accessibilityLabel`, `.help()`, `.accessibilityIdentifier`)
- **Does it touch Claude session lifecycle?** (hooks: `SessionStart`, `Stop`, `Notification`, `PermissionRequest`, etc.) — these usually need a `macSendHookEvent` step
- **Does it depend on terminal output?** — consider whether a content assertion (`tmuxCapturePaneContent` + `assertStoredContains`) gives better signal than a pixel screenshot
- **Does it require an "old version" / mismatch?** — use the `appVersion`/`minRequiredPartnerVersion` overrides on `launchIOSApp` / `launchMacApp` and `iosSetAppVersion` / `macSetAppVersion`
- **Does it model a sustained outage?** — `serverBlockDevice` + `serverUnblockDevice` (vs. transient `serverDisconnectDevice`)

Think about what a user would do to exercise this feature end-to-end. The scenario should simulate that user journey.

### Phase 2: Design the scenario

Based on the PR analysis, decide:

1. **What setup is needed?** Pick the right foundation:
   - Feature needs both iOS + macOS paired → compose with `FreshPairingScenario.scenario`
   - Feature is macOS-only → use `Shortcut.macOnlySetup`
   - Feature needs two Mac instances (host + viewer) → use `Shortcut.twoMacPairing`, then `Shortcut.openPanesWindow(instance: 0/1)` as needed
   - Feature needs a Mac viewer added to an iOS+host pairing → `FreshPairingScenario.scenario` then `Shortcut.addMacViewer`
   - Feature needs a tmux session → add `tmuxCreateSession` + pane selection steps
   - Feature needs Claude sessions to exist → `tmuxStorePaneId` + `macSendHookEvent({SessionStart})`
   - Feature needs deterministic terminal output → `injectScript(name:)` of a Python helper from `Scenarios/Scripts/`
   - Feature is version-mismatch → launch with explicit `appVersion` / `minRequiredPartnerVersion`

2. **What instance do steps target?** Two-Mac scenarios use `instance: 0` (host) and `instance: 1` (viewer). Most macOS steps accept the parameter — pick the right one for each step.

3. **What steps exercise the feature?** Map the user journey to TestStep calls. Prefer existing shortcuts and waitForElement variants over fixed sleeps. Use `Shortcut.iosTapCommandsMenuItem` / `iosVerifyCommandsMenuItem` for iOS toolbar Commands menu interactions.

4. **Where should screenshots go?** Place screenshots at moments that prove the feature works:
   - After the feature's UI first appears
   - After key interactions with the feature
   - After the feature completes its primary purpose
   - On both platforms (and both instances) if the feature spans multiple components — use `host-` / `viewer-` label prefixes for two-Mac scenarios

5. **Could a content assertion replace a screenshot?** For text-only features (terminal output, clipboard sync, file generation), `assertStoredContains` is more robust than a pixel comparison and produces a readable failure message. Pair with screenshots only where visual layout matters.

### Phase 3: Write the scenario

Create the scenario file in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/`.

#### Mandatory rules

- **Default to `compare: true`** — this is the default, so simply omit the `compare` parameter. Only pass `compare: false` when the captured content genuinely varies between runs (live timestamps, animations in flight). If a screenshot is unreliable for fixable reasons (timing, layout race), fix the root cause instead of disabling comparison.
- **Screenshot labels must start with a platform prefix:** `ios-`, `mac-`, `host-`, or `viewer-` (host/viewer in two-Mac scenarios)
- **Use `public enum` with a `public static let scenario`** property
- **Use `ClaudeSpyE2ELib.scenario(...)` factory** with descriptive name and relevant tags
- **No cleanup steps** — the orchestrator handles cleanup automatically (apps, server, tmux, blocked devices, injected scripts)
- **No manual number prefixes in labels** — auto-numbered by the framework
- **Use existing Shortcuts** — don't duplicate setup steps that shortcuts already provide
- **Add numbered phase comments** — group steps into logical phases with `// 1. Description`
- **Avoid `wait(seconds:)` whenever a state-driven wait works.** Never put a fixed `wait` directly before a `*WaitFor*` step (`iosWaitForElement`, `macWaitForElement`, `macWaitForElementQuery`, `waitForHostConnected`, `verifyServerHasPairings`, `waitForTmuxDisplayMessage`, `waitForFileContains`) or before `iosTap` / `macClickButton` (both wait up to 5s for their target internally). Prefer `*WaitForElement*`, `waitForTmuxDisplayMessage`, or `waitForFileContains` over fixed sleeps. See e2e-testing skill `references/patterns.md` "Waiting for UI Transitions" for the full checklist.

#### Adding accessibility hooks

If the new UI isn't discoverable by ElementQuery / `macClickButton`, see "Step 3: Add Accessibility Hooks" in the e2e-testing skill — the rules apply unchanged: `.accessibilityLabel` / `.accessibilityIdentifier` on iOS; `.help()` for macOS toolbar buttons; `Button` (not `onTapGesture`) with `.accessibilityLabel()` for sidebar/List rows; `macCGClick` for List selection vs `macClickButton` for AXPress; `macContextMenuClick(elementTitle:menuItem:)` for `.contextMenu` actions.

#### Register the scenario

Add it to the **end** of the `allScenarios` array in `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift`.

### Phase 4: Build and run

Run the scenario:

```bash
./scripts/e2e-test.sh --scenario "Scenario Name"
```

If it fails:
1. Read the error output carefully. The orchestrator auto-captures a `failure-step-NN-<target>.png` for any non-screenshot failure — open it to see the actual UI state at the moment of failure before guessing.
2. Determine if the fix belongs in the scenario (wrong query, missing wait, wrong element, wrong instance) or in app code (missing accessibility hook, timing issue).
3. Fix the issue.
4. Delete any stale baselines: `rm -rf E2ETests/<scenario-dir>/`
5. Re-run until it passes.

While iterating, you can drop baseline comparison entirely with `--no-compare` to focus on logic correctness, then re-enable it once the steps are right.

Common fixes:
- **Element not found** → add `iosLogUI` (or read the failure screenshot for macOS) before the failing step, run again, find the correct query. If the tree dump still doesn't tell you which entry to target — or if you need to discover macOS attributes (`.help()`, `accessibilityLabel`, identifier) — switch to the **`e2e-manual-debugging`** skill: it boots an interactive e2e instance and walks through inspecting the live UI (XCUITest hierarchy, AppleScript, Xcode Accessibility Inspector) to find exact labels and identifiers. Faster than guess-and-rerun.
- **Screenshot mismatch** → delete the baseline and re-run to regenerate
- **Timing issue** → switch from `wait(seconds:)` to `iosWaitForElement` / `macWaitForElement` / `waitForTmuxDisplayMessage` / `waitForFileContains`
- **macOS button not found** → check whether the element exposes `.help()` vs `.accessibilityLabel()`; for List rows try `macCGClick`. Use `e2e-manual-debugging` to read the actual attributes if you can't tell from the SwiftUI source.
- **Wrong instance targeted** → verify each `instance:` parameter; default is 0 (host)

### Phase 5: Verify screenshots (critical)

After the scenario passes, verify every screenshot baseline visually. Do not just check pass/fail status.

For each screenshot in `E2ETests/<scenario-name>/`:
1. Read the PNG file
2. Confirm it shows the expected content for that point in the scenario
3. Check that the new feature is actually visible and working in the screenshot
4. For two-Mac scenarios, verify host- and viewer- prefixed screenshots show the right side

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

Compare screenshots across runs — they should be consistent. If a screenshot differs between runs, investigate the flakiness source (animation timing, async content loading, non-deterministic timestamps) and fix it before finalizing.

### Phase 7: Report results

After all runs pass with verified screenshots, summarize:
- What the scenario tests (the user journey it simulates)
- How many screenshots it takes and what each one proves
- Any app code changes made (accessibility hooks, etc.)
- Files created/modified

## Worked design choices

These illustrate Phase 2 design — the rest of the workflow follows the same recipe regardless of feature.

**iOS star/favorite button on session rows** — `FreshPairingScenario` + `tmuxStorePaneId` + `macSendHookEvent(SessionStart)` to seed a session. Tap star, switch to Favorites filter, screenshot before/after. Pure iOS UI, no special outage modelling.

**Sessions list clears when host disconnects** — needs *both* iOS viewer and Mac viewer to verify clear-on-disconnect, so `FreshPairingScenario` + `Shortcut.addMacViewer`. Seed a session via `macSendHookEvent`. Use `serverBlockDevice(.host)` (sustained outage) — `serverDisconnectDevice` lets the host immediately reconnect inside the assertion window. Screenshot ios- and viewer- before/after for an obvious diff. Already implemented as `HostDisconnectClearsSessionsScenario`.

**Old-app version-mismatch warning** — `launchIOSApp(appVersion: "0.1", minRequiredPartnerVersion: "0.0")` to start the iOS side as an old build. After the warning UI is verified, call `iosSetAppVersion(appVersion: nil, minRequiredPartnerVersion: nil)` to simulate "user updated the app" and assert recovery. See `VersionMismatchOldIOSViewerScenario`.

## What this skill does NOT do

- Fix existing failing scenarios → use `e2e-testing` skill
- Manual interactive debugging → use `e2e-manual-debugging` skill
- Review or compare baselines → use `baseline-review` skill
- Write unit tests → this is specifically for E2E scenarios
