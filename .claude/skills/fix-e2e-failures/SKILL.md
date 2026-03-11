---
name: fix-e2e-failures
disable-model-invocation: true
description: Investigate and fix E2E test failures from the latest test report. Use this skill when the user mentions E2E failures, broken tests, test report errors, failing screenshots, baseline mismatches, updating baselines, or wants to fix a failing E2E scenario. Also use when someone says "fix the test", "deal with the test failure", "check the e2e report", "update baselines", or references a PR comment about E2E failures. Do NOT use this for writing new E2E tests (use e2e-testing) or for manual debugging (use e2e-manual-debugging).
allowed-tools:
  - AskUserQuestion
  - Read
  - Read(../ClaudeSpyTestResults/**)
  - Write
  - Bash(git *)
---

# Fix E2E Test Failures

This skill handles E2E test failures reported in the ClaudeSpyTestResults repository. It finds the latest failing report, identifies what broke, and guides the fix.

## Step 1: Find the Latest Failing Report

The test results live in a sibling repository at `../ClaudeSpyTestResults/`.

First, pull the latest results:

```bash
git -C ../ClaudeSpyTestResults pull --rebase 2>/dev/null || true
```

Then read `../ClaudeSpyTestResults/results/index.json` to find the most recent run with failures. The index is sorted newest-first. Look for entries where `allPassed` is `false` and `buildFailed` is `false` (build failures need separate handling — inform the user the build itself failed and there are no test results to analyze).

If no failing report exists, tell the user all recent E2E runs passed and stop.

## Step 2: Load the Report and Identify Failures

Read the report at `../ClaudeSpyTestResults/results/<folder>/report.json`.

The report structure is:
```json
{
  "metadata": {
    "branch": "feature-branch",
    "commit": "abc1234",
    "commitFull": "abc1234...",
    "commitMessage": "...",
    "prNumber": "207",
    "prUrl": "https://github.com/gpambrozio/ClaudeSpy/pull/207"
  },
  "scenarios": [
    {
      "scenarioName": "Scenario Name",
      "success": false,
      "error": "error description",
      "failedStep": 19,
      "steps": [
        {
          "stepNumber": 1,
          "description": "step description",
          "success": true,
          "error": null,
          "screenshot": {
            "label": "screenshot-label",
            "imageHash": "sha256hash",
            "baselineHash": "sha256hash",
            "diffHash": "sha256hash or null",
            "diffPercentage": 1.5,
            "passed": false,
            "baselineCreated": false
          }
        }
      ]
    }
  ]
}
```

Extract all failed scenarios — for each, note:
- The scenario name
- The error message
- The failed step number and description
- Whether it's a screenshot comparison failure (has `screenshot` with `passed: false`) or a functional failure

Present a summary to the user showing which scenarios failed and why.

## Step 3: Check Out the PR Branch

If the report has a `prNumber`, check out the PR's branch:

```bash
gh pr checkout <prNumber>
```

If there's no PR associated, check out the branch from the metadata directly:

```bash
git checkout <branch>
```

## Step 4: Examine Failure Details

For each failed scenario, look at:

1. **The failed step** — understand what the test was trying to do
2. **Screenshot failures** — if the step has a screenshot with `passed: false`, view the images:
   - Actual image: `../ClaudeSpyTestResults/images/<imageHash>.png`
   - Baseline image: `../ClaudeSpyTestResults/images/<baselineHash>.png`
   - Diff image (if exists): `../ClaudeSpyTestResults/images/<diffHash>.png`

   Use the Read tool to view these PNG files — it renders images visually.

3. **Functional failures** — read the error message carefully. Common causes:
   - Element not found (UI changed, accessibility label changed)
   - Timeout waiting for element (app state didn't reach expected state)
   - Image size mismatch (window dimensions changed)
   - Assertion failures (stored values don't match)

4. **The scenario source** — find it in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/` and read the relevant steps around the failure point.

## Step 5: Ask the User How to Proceed

Use the `AskUserQuestion` tool to ask the user:

> **E2E Failure in "[Scenario Name]"**
>
> [Brief description of what failed and why, including any screenshot observations]
>
> How would you like to handle this?
> 1. **Investigate and fix the bug** — The test is correct but the code has a regression. I'll look at the PR changes to find the cause and fix it.
> 2. **Update baseline images** — The UI change is intentional. I'll regenerate the baselines for the affected scenarios.

If there are multiple failed scenarios, present them all together so the user can decide on each one. The user may choose different strategies for different failures.

## Path A: Investigate and Fix the Bug

When the user chooses to investigate and fix:

1. **Understand the PR changes** — Run `git diff main...HEAD` to see all changes in the PR. Focus on changes that could affect the failing scenario.

2. **Look at relevant screenshots** — Compare actual vs baseline images to understand visually what changed.

3. **Trace the root cause** — Connect the failing test step to the code change that caused it. Common patterns:
   - Layout changes affecting screenshot comparisons
   - Renamed accessibility labels breaking element queries
   - Changed state management affecting UI timing
   - New UI elements overlapping existing ones

4. **Fix the code** — Make the minimal fix needed. This might be in the app code (if there's a genuine regression) or in the test scenario (if the test expectations need adjustment).

5. **Run the failing scenario** to verify the fix:
   ```bash
   ./scripts/e2e-test.sh --scenario "Scenario Name"
   ```

   If it still fails, iterate.

6. **Keep fixing until the test passes.** Don't stop at the first attempt — read the new error, adjust, and re-run.

## Path B: Update Baseline Images

When the user confirms the UI change is intentional:

1. **Delete the baseline directory** for each affected scenario:
   ```bash
   rm -rf E2ETests/<scenario-directory>/
   ```

   The scenario directory name is the scenario name sanitized (lowercased, spaces to hyphens). It's inside a numbered prefix directory. Find it with:
   ```bash
   ls E2ETests/ | grep -i "<partial-scenario-name>"
   ```

2. **Run the affected scenarios** to regenerate baselines:
   ```bash
   ./scripts/e2e-test.sh --scenario "Scenario Name"
   ```

   The first run creates new baselines and passes automatically.

3. **Review the new baselines** — Read the newly generated PNG files from `E2ETests/<scenario-directory>/` using the Read tool (it renders images). Start with the screenshots that previously failed, then check others to make sure they look reasonable.

4. **Present findings to the user** — Show the new baseline images and explain what they depict. Use AskUserQuestion to ask the user to confirm the new baselines look correct before proceeding.

5. **Once confirmed**, the new baselines are ready. Inform the user the baselines have been updated and they can commit when ready.

## Important Notes

- The E2E tests require Accessibility and Screen Recording permissions for the terminal running them.
- Always use `--skip-build` when re-running tests if you haven't changed compiled code, to save time.
- If you changed Swift source code or after checking out from git, drop `--skip-build` so the changes get compiled.
- Screenshot baselines live in `E2ETests/` with numbered prefixes matching scenario registration order in `ClaudeSpyE2ECommand.swift`.
- The `--scenario` flag accepts the human-readable scenario name (e.g., "Fresh Pairing", "Empty State New Session").
