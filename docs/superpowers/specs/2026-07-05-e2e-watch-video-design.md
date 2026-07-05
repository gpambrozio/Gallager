# E2E Watch Video — In-Browser Playback of Proof Videos

**Date:** 2026-07-05
**Status:** Approved

## Problem

`scripts/e2e-attach-video.sh` uploads `--record` videos as release assets on the
private `gpambrozio/ClaudeSpyTestResults` repo and links them in a PR comment.
GitHub serves release-asset links with an attachment disposition, so clicking a
link downloads the file — the reviewer then has to find and open it locally.
The goal: watch a proof video inline in the browser.

## Constraint (verified empirically)

The results repo is private, which blocks every pure-browser approach:

- The `github.com/…/releases/download/…` URL only works as a top-level
  navigation carrying the github.com session cookies (SameSite-Lax); a page on
  any other origin gets a 404.
- The API route (`Authorization` + `Accept: application/octet-stream`) 302s to
  a signed `release-assets.githubusercontent.com` URL, but that final response
  carries **no `Access-Control-Allow-Origin` header**, so a hosted player's
  `fetch` dies at the last hop even with a valid token. (The 302 itself and
  `api.github.com` do send `ACAO: *`.)

What does work: the signed URL is public for ~1 hour, supports byte-range
seeking (`accept-ranges: bytes`), and plays fine as a `<video src>` because
media-element loads are no-cors. Something holding `gh` credentials just has
to resolve the redirect *outside* the browser.

## Decision

**Local helper + committed static player page.** Zero infrastructure, videos
stay private. Rejected alternatives: a public videos-only repo with a GitHub
Pages player (one-click UX but makes videos world-readable), and a relay-server
player + signed-URL proxy endpoint (keeps videos private with one-click UX but
needs a server-side GitHub token and a deploy).

## Components

### 1. `scripts/e2e-video-player.html`

Static, dependency-free player committed to the repo. Reads parameters from
the URL **fragment** (`#src=<encoded-url>&title=<name>`) — fragment rather
than query string so `open`/LaunchServices and `file://` handling can't mangle
it. Minimal dark-friendly page: asset name as title, `<video controls
autoplay>` pointed at the src. On a media error it explains the likely cause —
the signed URL expired (~1 hour) — and shows the watch command to re-run.

### 2. `scripts/e2e-watch-video.sh TARGET [TARGET ...]`

Mirrors `e2e-attach-video.sh` conventions and flags (`--pr`, `--results-repo`,
`--release-tag`). Each TARGET resolves, in order:

1. Full release-download URL
   (`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`) →
   owner/repo/tag/asset parsed from the URL.
2. Asset name (`pr626-foo.mp4`; `.mp4` optional) → default repo/tag.
3. Local file path, or scenario dir containing `video.mp4` → opened directly
   with `open` (QuickTime); no signed-URL dance.
4. Scenario name/dir → sanitized via `e2e_report_build.scenario_dir_name`
   (same parity-tested helper the attach script uses) + PR number from `--pr`
   or the current branch → `pr<N>-<dir>.mp4`.

For remote assets: fetch the release by tag via `gh api`, match the asset by
name, resolve the signed URL by reading the 302 `Location` header (curl with
`gh auth token`, not following the redirect), then `open` the player with the signed
URL in the fragment. Unknown asset → error that lists the release's available
`pr<N>-*` assets. Multiple targets open one browser tab each.

### 3. `e2e-attach-video.sh` PR-comment hint

Each video line in the posted comment gains a copy-pasteable sub-line:

```
- **▶ [Title](url)** — 21s (speedup), 135 steps
  watch: `./scripts/e2e-watch-video.sh pr626-subagent-stop-ignored.mp4`
```

### 4. Docs

`docs/e2e-testing.md` video-recording section gains a short "watching videos"
note pointing at the script.

## Error handling

- Missing `gh`/`jq`/`python3` → same preflight error as the attach script.
- Asset not found on the release → list available assets and exit 1.
- No PR resolvable for a scenario-name target → same error as attach script
  (`pass --pr N`).
- Expired signed URL at playback time → player-page error panel (see above).

## Testing

- Manual: run against an existing asset (e.g. `pr622-cursor-style-changes.mp4`),
  verify playback, seeking, and the expired-URL error panel (tamper the sig).
- `scripts/tests/`: add coverage for TARGET parsing/resolution if it fits the
  existing test pattern there; playback itself stays manual.
