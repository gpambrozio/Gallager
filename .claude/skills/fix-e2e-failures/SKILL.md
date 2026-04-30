---
name: fix-e2e-failures
disable-model-invocation: true
description: Investigate and fix E2E test failures from the latest test report. Use this skill when the user mentions E2E failures, broken tests, test report errors, failing screenshots, baseline mismatches, updating baselines, or wants to fix a failing E2E scenario. Also use when someone says "fix the test", "deal with the test failure", "check the e2e report", "update baselines", or references a PR comment about E2E failures. Do NOT use this for writing new E2E tests (use e2e-testing) or for manual debugging (use e2e-manual-debugging).
allowed-tools:
  - AskUserQuestion
  - Read
  - Read(/../ClaudeSpyTestResults/**)
  - Write
  - Bash(git *)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/find_failures.py *)
---

# Fix E2E Test Failures

This skill handles E2E test failures reported in the ClaudeSpyTestResults repository. It finds the latest failing report, identifies what broke, and guides the fix.

## How failures are reported

Screenshot mismatches are **non-fatal** in the orchestrator — after a failed screenshot comparison the scenario keeps running, so a single scenario can produce **multiple failed steps**. Only a non-screenshot error (element not found, timeout, assertion failure, etc.) stops the scenario early.

This means each failing scenario may have:
- One or more screenshot mismatches (scenario ran to completion), OR
- Zero or more screenshot mismatches followed by a fatal functional error (scenario stopped at that point).

Handle every failed step — don't stop at the first one.

## Step 1: Find Failures

Run the bundled script to pull latest results and extract failures in one step:

```bash
${CLAUDE_SKILL_DIR}/scripts/find_failures.py --results-dir ../ClaudeSpyTestResults
```

The script outputs JSON with one of these statuses:
- `"all_passed"` — No failures found. Tell the user and stop.
- `"build_failed"` — The build itself failed, no test results. Inform the user.
- `"no_results"` — Results directory not found. Check the path.
- `"failures_found"` — Failures detected. Continue to Step 2.

When `status` is `"failures_found"`, the output includes:
- `metadata` — branch, commit, PR URL
- `failures[]` — one entry per failed **scenario** (not per step). Each entry has:
  - `scenarioName`
  - `error` — the scenario's top-level error (typically from the first failure)
  - `failedStep` — first failed step number (back-compat field)
  - `failedSteps[]` — **every** failed step in the scenario, each with `stepNumber`, `description`, `error`, `type` (`"functional"` or `"screenshot_mismatch"`), `screenshot` (with paths to `actualImage`/`baselineImage`/`diffImage` when applicable), and `failureScreenshots[]` (diagnostic captures — see below)
  - `hasFatalFailure` — `true` if any failed step was non-screenshot (scenario aborted early)
- `message` — human-readable summary grouped by scenario

Present the `message` summary to the user.

## Step 2: Check Out the PR Branch

If the output has `metadata.prNumber`, check out the PR's branch:

```bash
gh pr checkout <prNumber>
```

If there's no PR associated, check out the branch from the metadata directly:

```bash
git checkout <branch>
```

## Step 3: Examine Failure Details

For each failed scenario, walk through **every** entry in `failedSteps[]`:

1. **The failed step** — read `description` to understand what the test was trying to do.

2. **Screenshot mismatches** — when `type` is `"screenshot_mismatch"`, view the images using the Read tool (it renders PNGs visually):
   - `screenshot.actualImage` — what the test produced
   - `screenshot.baselineImage` — what was expected
   - `screenshot.diffImage` — visual diff (if available)

   A scenario may have several screenshot mismatches. If they all share a common visual change (e.g. a moved control, a new element, a color shift), they likely stem from a single underlying cause — check all of them before deciding how to handle the scenario.

3. **Functional failures** — when `type` is `"functional"`, read the error carefully. If `hasFatalFailure` is true, remember the scenario stopped at that step; any later steps that were planned did not run. Common causes:
   - Element not found (UI changed, accessibility label changed)
   - Timeout waiting for element (app state didn't reach expected state)
   - Image size mismatch (window dimensions changed)
   - Assertion failures (stored values don't match)

4. **Failure screenshots** — when a step has a non-empty `failureScreenshots[]`, the orchestrator captured the UI of every running platform that was relevant to the failed step's scope. Each entry has `target` (`"ios"`, `"mac"`, `"mac2"`, ...) and `image` (a path to a PNG in the results image store). **Always view these with the Read tool before deciding the cause** — they show what was on screen at the moment the step failed and are usually the fastest way to tell:
   - Whether an element really wasn't there (vs. being there with a different label/identifier)
   - Whether the app got stuck on a modal/sheet/alert that the test wasn't expecting
   - Which platform diverged when an assertion fails on a value synced across iOS + macOS instances
   - Whether two-Mac scenarios show the host and viewer in different states

   `.universal`-scope step failures (assertions, server, tmux, generic helpers) capture every running platform, so expect multiple images. `.ios`/`.macOS(N)`-scope step failures capture only the targeted platform.

5. **The scenario source** — find it in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/` and read the relevant steps around each failure point.

## Step 4: Ask the User How to Proceed

Use the `AskUserQuestion` tool to ask the user how to handle each failing scenario. Because a scenario can have multiple failures, present it as a grouped decision per scenario:

> **E2E Failures in "[Scenario Name]"** ([N] failed step(s))
>
> - Step 47: [screenshot_mismatch] viewer-pane-selected (3.0% diff) — [brief visual observation]
> - Step 69: [screenshot_mismatch] viewer-updated-title (3.6% diff) — [brief visual observation]
> - Step 75: [functional] timeout waiting for element "Send" — [brief note]
>
> How would you like to handle this scenario?
> 1. **Investigate and fix the bug** — The test is correct but the code has a regression. I'll look at the PR changes to find the cause and fix it.
> 2. **Update baseline images** — The UI change is intentional. I'll regenerate the baselines for the affected scenarios.
> 3. **Mixed** — Describe which failures are bugs and which are intentional UI changes.

If there are multiple failed scenarios, present them all together so the user can decide on each one. The user may choose different strategies for different scenarios.

**Important:** If `hasFatalFailure` is `true`, option 2 alone is not enough — the fatal step must be fixed as well (see Path A). Baseline regeneration won't help a timeout or missing-element error.

## Step 5: Follow the Chosen Path (see below)

## Step 6: Commit and Push Changes

## Step 7: Notify user and ask if it's ready for CI

Use the AskUserQuestion tool to ask the user if they want to trigger CI. If yes, add the "ready for testing" label to the pr. If not just stop.

## Path A: Investigate and Fix the Bug

When the user chooses to investigate and fix:

1. **Understand the PR changes** — Run `git diff main...HEAD` to see all changes in the PR. Focus on changes that could affect the failing scenario.

2. **Look at relevant screenshots** — Compare actual vs baseline images for every screenshot failure to understand visually what changed. Look for common themes across multiple failures in the same scenario — one underlying change often produces several mismatches.

3. **Trace the root cause** — Connect the failing test steps to the code change that caused them. Common patterns:
   - Layout changes affecting screenshot comparisons
   - Renamed accessibility labels breaking element queries
   - Changed state management affecting UI timing
   - New UI elements overlapping existing ones

4. **Fix the code** — Make the minimal fix needed. This might be in the app code (if there's a genuine regression) or in the test scenario (if the test expectations need adjustment).

5. **Run the failing scenario** to verify the fix:
   ```bash
   ./scripts/e2e-test.sh --scenario "Scenario Name"
   ```

   If it still fails, iterate. Remember: a scenario can now report multiple failures in one run, so after each attempt re-read the report and confirm **every** previously failing step now passes — not just the first one.

6. **Keep fixing until the test passes.** Don't stop at the first attempt — read the new error, adjust, and re-run.

## Path B: Update Baseline Images

When the user confirms the UI change is intentional:

1. **Delete the baseline directory** for each affected scenario:
   ```bash
   rm -rf E2ETests/<scenario-directory>/
   ```

   Deleting the whole directory regenerates every baseline for that scenario, which is usually what you want when multiple screenshots in the same scenario have shifted. The scenario directory name is the scenario name sanitized (lowercased, spaces to hyphens). Find it with:
   ```bash
   ls E2ETests/ | grep -i "<partial-scenario-name>"
   ```

2. **Run the affected scenarios** to regenerate baselines:
   ```bash
   ./scripts/e2e-test.sh --scenario "Scenario Name"
   ```

   The first run creates new baselines and passes automatically for every screenshot in the scenario.

3. **Review the new baselines** — Read the newly generated PNG files from `E2ETests/<scenario-directory>/` using the Read tool (it renders images). Start with every screenshot that previously failed (there may be several), then spot-check the rest to make sure they look reasonable.

4. **Present findings to the user** — Show the new baseline images and explain what they depict. Use AskUserQuestion to ask the user to confirm the new baselines look correct before proceeding.

5. **Once confirmed**, the new baselines are ready. Remove them from git so that CI will re-generate them.

## Important Notes

- The E2E tests require Accessibility and Screen Recording permissions for the terminal running them.
- Always use `--skip-build` when re-running tests if you haven't changed compiled code, to save time.
- If you changed Swift source code or after checking out from git, drop `--skip-build` so the changes get compiled.
- Screenshot baselines live in `E2ETests/` with numbered prefixes matching scenario registration order in `ClaudeSpyE2ECommand.swift`.
- The `--scenario` flag accepts the human-readable scenario name (e.g., "Fresh Pairing", "Empty State New Session").
- **Screenshot mismatches are non-fatal.** A single scenario run can report multiple failed screenshots; treat every entry in `failedSteps[]` as something to resolve, not just the first one.
- **Baselines are not automatically regenerated** — If existing baselines are present, the test compares against them and fails on mismatch. To regenerate baselines, you must either delete the baseline directory first (`rm -rf E2ETests/<scenario-directory>/`) so the next run creates fresh baselines, or run with `--no-compare` to skip all screenshot comparisons (the test still takes screenshots but won't fail on mismatches).
- **Never commit screenshot baselines** — Baselines in `E2ETests/` are generated by CI and must not be pushed to GitHub. If changes cause existing baselines to become invalid (e.g., UI changes, new/reordered screenshots), delete the affected baseline directory so CI regenerates them.
