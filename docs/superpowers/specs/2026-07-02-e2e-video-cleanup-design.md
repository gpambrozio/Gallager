# E2E Proof-Video Cleanup — Design

**Date:** 2026-07-02
**Status:** Approved

## Problem

`scripts/e2e-attach-video.sh` uploads E2E proof videos as release assets named
`pr<N>-<scenario-dir>[-<label>].mp4` on the rolling `e2e-videos` prerelease of
`gpambrozio/ClaudeSpyTestResults`, and posts a PR comment on ClaudeSpy linking
them. The assets are explicitly ephemeral ("may be deleted after review"), but
nothing deletes them — merged PRs leave orphaned videos behind (e.g. the
`pr622-*` assets today). Manual `gh release delete-asset` is the only cleanup.

## Goal

When a ClaudeSpy PR merges or closes, its proof videos are deleted
automatically after a **3-day grace period**, and the PR comment that linked
them is edited so readers don't click dead links.

## Approach

A **daily scheduled sweep in the ClaudeSpy repo** (not event-driven, not in the
results repo):

- A sweep tolerates the grace period naturally; GitHub Actions has no clean
  "run 3 days after the close event" primitive.
- A sweep also catches already-orphaned assets (like `pr622-*`) that any
  event-based approach would miss.
- Living in ClaudeSpy keeps the cleanup next to the upload script whose naming
  convention it depends on, so they evolve in the same PRs, and lets the
  workflow's own `GITHUB_TOKEN` handle all ClaudeSpy-side operations
  (PR-state reads, comment edits). Both repos are private, so one cross-repo
  PAT is required in either direction; this direction needs the narrower one
  (Contents-only on the results repo).

## Components

### `scripts/e2e_video_cleanup.py`

Single Python script (no bash wrapper — the sweep is mostly logic, not `gh`
plumbing): `argparse` for flags, `subprocess` for `gh` calls, `json` instead
of `jq`. Snake_case module name so the unit test imports it directly
(`e2e_report_build.py` precedent); shebang + executable bit so the workflow
runs it as a script. Runnable locally (the owner's `gh` auth reaches both
repos; no env vars needed).

Flags:

- `--results-repo SLUG` (default `gpambrozio/ClaudeSpyTestResults`)
- `--release-tag TAG` (default `e2e-videos`)
- `--grace-days N` (default `3`)
- `--repo SLUG` — the PR repo (default `gpambrozio/Gallager`)
- `--dry-run` — print what would be deleted/edited; mutate nothing

Tokens: all results-repo calls use `RESULTS_REPO_TOKEN` when set (falling back
to ambient `gh` auth locally); all PR-repo calls use the ambient token
(`GITHUB_TOKEN` in CI).

Algorithm:

1. List assets on the release. Release missing → exit 0 quietly.
2. Group assets matching `^pr([0-9]+)-.*\.mp4$` by PR number. Non-matching
   assets are left alone.
3. Per PR: `gh pr view N --json state,closedAt`. **Eligible** iff state is
   `MERGED` or `CLOSED` and `closedAt` is more than `--grace-days` ago.
   Open PRs (including closed-then-reopened within grace) are skipped. A PR
   lookup failure skips that PR with a warning — never delete on uncertainty.
4. Delete each eligible asset (`gh release delete-asset`), collecting the
   names that actually deleted.
5. Mark comments (below) for successfully deleted assets only. A comment-edit
   failure exits non-zero (red run, visible in the log) but assets stay
   deleted; there is nothing to retry on the next run. Accepted trade-off.

The pure logic lives in plain functions (unit-testable without mocking `gh`):

- **Comment rewrite:** given a comment body and the deleted asset URLs,
  replace each markdown link `[Title](url)` whose URL was deleted with
  `~~Title~~` (the `▶` sits outside the link in the upload script's format,
  so it is kept), and append one italic line:
  `_Proof videos deleted after the post-merge grace period._`
  Idempotent by construction — once rewritten, the URL is gone from the body,
  so later sweeps find nothing to edit.
- **Eligibility check:** `closedAt` + grace days vs. now.

Unit-tested in `scripts/tests/` following the `test_e2e_report_build.py`
precedent.

### `.github/workflows/e2e-video-cleanup.yml`

- Triggers: daily cron (`0 15 * * *` UTC) + `workflow_dispatch` with a
  `dry_run` input (maps to `--dry-run`).
- `runs-on: ubuntu-latest`; checkout, then run the script.
- Permissions: `pull-requests: read` (PR state), `issues: write` (PR comments
  are issue comments).
- Env: `GH_TOKEN: ${{ github.token }}`,
  `RESULTS_REPO_TOKEN: ${{ secrets.RESULTS_REPO_TOKEN }}`.

### Secret: `RESULTS_REPO_TOKEN`

Fine-grained PAT scoped to **only** `ClaudeSpyTestResults`, permission
**Contents: read/write** (release assets fall under Contents). Created
manually in the GitHub UI; stored with
`gh secret set RESULTS_REPO_TOKEN --repo gpambrozio/Gallager`.

## Edge cases

| Case | Behavior |
|---|---|
| PR reopened within grace period | State is `OPEN` at sweep time → skipped, videos kept |
| PR reopened after deletion | Videos gone; re-upload with `e2e-attach-video.sh` if needed |
| Asset name doesn't match `pr<N>-*.mp4` | Left alone |
| PR number doesn't resolve | Warn + skip (conservative) |
| Release doesn't exist | Exit 0 quietly |
| Comment already edited / deleted manually | URL absent → no-op |
| Asset deleted but comment edit fails | Non-zero exit; red run flags it for manual follow-up |

## Testing & rollout

1. Unit tests for the rewrite + eligibility logic (`scripts/tests/`).
2. Local `--dry-run` against the real release — the orphaned `pr622-*` assets
   are a live test case.
3. Owner creates the PAT and sets the `RESULTS_REPO_TOKEN` secret.
4. First real run via `workflow_dispatch`; verify `pr622-*` assets are deleted
   and PR #622's comment is marked.
