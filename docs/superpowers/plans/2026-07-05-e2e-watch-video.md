# E2E Watch Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play e2e proof videos (private-repo release assets uploaded by `e2e-attach-video.sh`) inline in the browser via a local helper script + committed static player page.

**Architecture:** GitHub serves private release assets with an attachment disposition and no CORS on the final signed-URL hop, so no hosted page can fetch them. But the ~1-hour signed URL plays fine as a `<video src>` (media loads are no-cors, byte-range seeking supported). `scripts/e2e-watch-video.sh` resolves that signed URL using existing `gh` credentials, then opens `scripts/e2e-video-player.html` with `#src=<url>&title=<asset>` in the fragment (fragment, not query, so `file://` handling can't mangle it; a tiny launcher HTML in the e2e tmpdir does a `location.replace` so the fragment survives `open`/LaunchServices).

**Tech Stack:** bash (mirrors `scripts/e2e-attach-video.sh` conventions), `gh`/`jq`/`curl`/`python3` (all already required or preinstalled), single dependency-free static HTML page. No unit-test harness: the repo's bash scripts (`e2e-attach-video.sh` precedent) are verified manually; the only pure logic (scenario-name sanitizing) reuses the already-parity-tested `e2e_report_build.scenario_dir_name`.

**Spec:** `docs/superpowers/specs/2026-07-05-e2e-watch-video-design.md`

## Global Constraints

- Default results repo `gpambrozio/ClaudeSpyTestResults`, default release tag `e2e-videos` — both overridable via `--results-repo` / `--release-tag`, exactly like `e2e-attach-video.sh`.
- Asset naming is `pr<N>-<scenario-dir>.mp4` (what the attach script uploads).
- The player page must be fully static and dependency-free (no CDN, no build step).
- Parameters ride the URL **fragment** (`#src=…&title=…`), never the query string.
- Signed URLs expire in ~1 hour; the player's error panel must say so and show the rerun command.
- All new scripts follow `e2e-attach-video.sh` house style: `set -eo pipefail`, `usage()`, tool preflight loop, uppercase config vars.

---

### Task 1: Static player page

**Files:**
- Create: `scripts/e2e-video-player.html`

**Interfaces:**
- Produces: a page that reads `location.hash` as URL-encoded params `src` (video URL) and `title` (asset name, e.g. `pr622-cursor-style-changes.mp4`), plays `src` in `<video controls autoplay>`, and on media error shows a panel explaining signed-URL expiry with the rerun command `./scripts/e2e-watch-video.sh <title>`. Task 2 opens this page.

- [ ] **Step 1: Write the player page**

Create `scripts/e2e-video-player.html` with exactly this content:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>E2E proof video</title>
<!--
  Static player for e2e proof videos. Opened by scripts/e2e-watch-video.sh
  with the short-lived signed asset URL in the fragment:
      e2e-video-player.html#src=<url-encoded video URL>&title=<asset name>
  Fragment (not query string) so file:// handling can't strip or mangle it.
  Media-element loads are no-cors, which is why the signed URL plays even
  though fetch()ing it cross-origin does not work.
-->
<style>
  :root { color-scheme: dark; }
  body {
    margin: 0; min-height: 100vh;
    display: flex; flex-direction: column;
    align-items: center; justify-content: center; gap: 1rem;
    background: #111; color: #eee;
    font: 15px/1.5 -apple-system, system-ui, sans-serif;
  }
  h1 { font-size: 1rem; font-weight: 600; margin: 0; }
  video { max-width: 92vw; max-height: 80vh; background: #000; border-radius: 8px; }
  #error {
    display: none; max-width: 40rem; padding: 1rem 1.25rem;
    background: #3a1f1f; border: 1px solid #7f3b3b; border-radius: 8px;
  }
  code { background: #222; padding: 0.1em 0.35em; border-radius: 4px; }
</style>
</head>
<body>
<h1 id="title">E2E proof video</h1>
<video id="player" controls autoplay muted playsinline></video>
<div id="error"></div>
<script>
  const params = new URLSearchParams(location.hash.slice(1));
  const src = params.get("src");
  const title = params.get("title");
  if (title) {
    document.getElementById("title").textContent = title;
    document.title = title;
  }
  const video = document.getElementById("player");
  const errorPanel = document.getElementById("error");

  function showError(html) {
    video.style.display = "none";
    errorPanel.style.display = "block";
    errorPanel.innerHTML = html;
  }

  function escapeHTML(s) {
    const div = document.createElement("div");
    div.textContent = s;
    return div.innerHTML;
  }

  if (!src) {
    showError("No video URL given. Open this page via " +
      "<code>./scripts/e2e-watch-video.sh &lt;asset|url|scenario&gt;</code>.");
  } else {
    video.src = src;
    video.addEventListener("error", () => {
      const rerun = title ? " " + escapeHTML(title) : " &lt;asset&gt;";
      showError("Couldn't load the video — the signed URL has likely expired " +
        "(they're valid for about an hour). Re-run " +
        "<code>./scripts/e2e-watch-video.sh" + rerun + "</code> to get a fresh one.");
    });
  }
</script>
</body>
</html>
```

- [ ] **Step 2: Verify playback with a real signed URL**

Resolve a signed URL for an existing asset and open the player the same way Task 2's script will:

```bash
TOKEN=$(gh auth token)
ASSET_ID=$(gh api repos/gpambrozio/ClaudeSpyTestResults/releases/tags/e2e-videos \
  --jq '.assets[] | select(.name == "pr622-cursor-style-changes.mp4") | .id')
LOC=$(curl -fsS -o /dev/null -D - \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
  "https://api.github.com/repos/gpambrozio/ClaudeSpyTestResults/releases/assets/$ASSET_ID" \
  | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)
ENC=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$LOC")
mkdir -p "${TMPDIR:-/tmp}/claudespy-e2e"
cat > "${TMPDIR:-/tmp}/claudespy-e2e/watch-test.html" <<EOF
<!DOCTYPE html><meta charset="utf-8"><script>location.replace("file://$(pwd)/scripts/e2e-video-player.html#src=$ENC&title=pr622-cursor-style-changes.mp4");</script>
EOF
open "${TMPDIR:-/tmp}/claudespy-e2e/watch-test.html"
```

Expected: default browser opens, page title reads `pr622-cursor-style-changes.mp4`, video autoplays, seeking via the scrubber works. If any of that fails, fix the player before proceeding.

*Note: if `pr622-cursor-style-changes.mp4` has been cleaned up by the time this runs, substitute any asset name from `gh api repos/gpambrozio/ClaudeSpyTestResults/releases/tags/e2e-videos --jq '.assets[].name'`.*

- [ ] **Step 3: Verify the error panel**

```bash
open "file://$(pwd)/scripts/e2e-video-player.html#src=https%3A%2F%2Fexample.com%2Fnope.mp4&title=pr622-cursor-style-changes.mp4"
```

Expected: instead of a video, a red panel: "Couldn't load the video — the signed URL has likely expired (they're valid for about an hour). Re-run `./scripts/e2e-watch-video.sh pr622-cursor-style-changes.mp4` to get a fresh one."
(If this direct `open` drops the fragment on your machine and shows "No video URL given" instead, that's exactly why the launcher-redirect exists — retest by writing a launcher HTML as in Step 2 but with the bogus src.)

- [ ] **Step 4: Commit**

```bash
git add scripts/e2e-video-player.html
git commit -m "Add static player page for e2e proof videos

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Watch helper script

**Files:**
- Create: `scripts/e2e-watch-video.sh` (mode 755)

**Interfaces:**
- Consumes: `scripts/e2e-video-player.html` from Task 1 (fragment contract `#src=…&title=…`); `e2e_report_build.scenario_dir_name` (existing, parity-tested); `gh` auth.
- Produces: `./scripts/e2e-watch-video.sh [--pr N] [--screenshots DIR] [--results-repo SLUG] [--release-tag TAG] TARGET [TARGET ...]` — Task 3's PR-comment hint and docs reference this exact invocation shape.

- [ ] **Step 1: Write the script**

Create `scripts/e2e-watch-video.sh` with exactly this content:

```bash
#!/bin/bash

# E2E Video Watcher for ClaudeSpy
# Plays e2e proof videos (release assets uploaded by e2e-attach-video.sh) in
# the browser instead of downloading them.
#
# GitHub serves private release assets with an attachment disposition, and the
# signed-URL response carries no CORS headers, so no hosted page can fetch
# them. This script resolves the asset's short-lived signed URL (~1 hour)
# with gh credentials and opens scripts/e2e-video-player.html with that URL
# in the fragment — <video> media loads are no-cors, so playback and seeking
# work. A tiny launcher HTML does a location.replace so the fragment survives
# open/LaunchServices.
#
# TARGET forms (first match wins):
#   1. https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>
#   2. asset name: pr626-window-description-sync[.mp4]
#   3. local video file or scenario dir (opened directly, no GitHub round-trip)
#   4. scenario name/dir: pr<N>-<scenario-dir>.mp4 via --pr or current branch's PR

set -eo pipefail

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
E2E_TMPDIR="${TMPDIR:-/tmp}/claudespy-e2e"
SCREENSHOTS_DIR="$E2E_TMPDIR/e2e-screenshots"
RESULTS_REPO="gpambrozio/ClaudeSpyTestResults"
RELEASE_TAG="e2e-videos"
PLAYER="$SCRIPT_DIR/e2e-video-player.html"
PR_NUMBER=""
TARGETS=()

# =====================================================
# PARSE ARGUMENTS
# =====================================================
usage() {
    echo "Usage: $0 [OPTIONS] TARGET [TARGET ...]"
    echo ""
    echo "Plays e2e proof videos in the browser. Each TARGET is a release-asset"
    echo "download URL, an asset name (pr626-foo[.mp4]), a path to a local video"
    echo "file or scenario dir (played directly), or a scenario name."
    echo ""
    echo "Options:"
    echo "  --pr N              PR number for scenario-name targets"
    echo "                      (default: PR for current branch)"
    echo "  --screenshots DIR   Screenshots dir local scenario videos live under"
    echo "                      (default: $SCREENSHOTS_DIR)"
    echo "  --results-repo SLUG owner/repo hosting the release (default: $RESULTS_REPO)"
    echo "  --release-tag TAG   Release tag holding the assets (default: $RELEASE_TAG)"
    echo "  -h, --help          Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            PR_NUMBER="$2"
            shift 2
            ;;
        --screenshots)
            SCREENSHOTS_DIR="$2"
            shift 2
            ;;
        --results-repo)
            RESULTS_REPO="$2"
            shift 2
            ;;
        --release-tag)
            RELEASE_TAG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "ERROR: no target given."
    usage
    exit 1
fi

for tool in gh jq python3 curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool is required but not found on PATH."
        exit 1
    fi
done

# =====================================================
# HELPERS
# =====================================================

# Reuse the report pipeline's sanitizer (parity-tested against
# TestOrchestrator.scenarioDirName) — same helper e2e-attach-video.sh uses.
scenario_dir_name() {
    python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
from e2e_report_build import scenario_dir_name
print(scenario_dir_name(sys.argv[2]))
" "$SCRIPT_DIR" "$1"
}

# urlencode VALUE [SAFE-CHARS]
urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=sys.argv[2]))" "$1" "${2:-}"
}

# Local resolution: direct file path, dir with video.mp4, or raw dir name
# under SCREENSHOTS_DIR. Unlike e2e-attach-video.sh's resolve_video, there is
# deliberately NO sanitized-name lookup: a human-readable scenario name falls
# through to the remote pr<N>-<dir>.mp4 asset (form 4) — this script verifies
# what was uploaded, not the local recording.
resolve_local_video() {
    local arg="$1"
    if [ -f "$arg" ]; then
        echo "$arg"
        return 0
    fi
    if [ -d "$arg" ] && [ -f "$arg/video.mp4" ]; then
        echo "$arg/video.mp4"
        return 0
    fi
    if [ -f "$SCREENSHOTS_DIR/$arg/video.mp4" ]; then
        echo "$SCREENSHOTS_DIR/$arg/video.mp4"
        return 0
    fi
    return 1
}

# Resolve the short-lived signed URL for REPO TAG ASSET by reading the 302
# Location of the API's octet-stream response (without following it).
signed_url_for_asset() {
    local repo="$1" tag="$2" asset="$3"
    local asset_id token location
    asset_id=$(gh api "repos/$repo/releases/tags/$tag" \
        --jq ".assets[] | select(.name == \"$asset\") | .id" 2>/dev/null || true)
    if [ -z "$asset_id" ]; then
        echo "ERROR: asset '$asset' not found on release '$tag' of $repo." >&2
        echo "Available assets:" >&2
        gh api "repos/$repo/releases/tags/$tag" --jq '.assets[].name' 2>/dev/null \
            | sed 's/^/  /' >&2 || echo "  (release not found)" >&2
        return 1
    fi
    token=$(gh auth token)
    location=$(curl -fsS -o /dev/null -D - \
        -H @- \
        -H "Accept: application/octet-stream" \
        "https://api.github.com/repos/$repo/releases/assets/$asset_id" \
        <<<"Authorization: Bearer $token" \
        | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -1)
    if [ -z "$location" ]; then
        echo "ERROR: no redirect from the API for '$asset' — cannot resolve signed URL." >&2
        return 1
    fi
    echo "$location"
}

# Open the player page with ASSET's SIGNED-URL in the fragment. open(1) can
# drop fragments on file: URLs, so stage a launcher that location.replace()s.
open_player() {
    local asset="$1" signed="$2"
    local player_url launcher
    player_url="file://$(urlencode "$PLAYER" "/")#src=$(urlencode "$signed")&title=$(urlencode "$asset")"
    mkdir -p "$E2E_TMPDIR"
    launcher="$E2E_TMPDIR/watch-$asset.html"
    cat > "$launcher" <<EOF
<!DOCTYPE html><meta charset="utf-8"><script>location.replace("$player_url");</script>
EOF
    open "$launcher"
    echo "Playing $asset (signed URL valid ~1 hour)"
}

# =====================================================
# RESOLVE AND PLAY TARGETS
# =====================================================
for target in "${TARGETS[@]}"; do
    # 1) Full release-download URL
    if [[ "$target" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$ ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        tag="${BASH_REMATCH[3]}"
        asset="${BASH_REMATCH[4]}"
        signed=$(signed_url_for_asset "$repo" "$tag" "$asset")
        open_player "$asset" "$signed"
        continue
    fi

    # 2) Asset name
    if [[ "$target" =~ ^pr[0-9]+- ]]; then
        asset="$target"
        [[ "$asset" == *.mp4 ]] || asset="$asset.mp4"
        signed=$(signed_url_for_asset "$RESULTS_REPO" "$RELEASE_TAG" "$asset")
        open_player "$asset" "$signed"
        continue
    fi

    # 3) Local video file / scenario dir
    if video_path=$(resolve_local_video "$target"); then
        open "$video_path"
        echo "Playing local video: $video_path"
        continue
    fi

    # 4) Scenario name -> pr<N>-<scenario-dir>.mp4
    if [ -z "$PR_NUMBER" ]; then
        PR_NUMBER=$(cd "$PROJECT_ROOT" && gh pr view --json number --jq '.number' 2>/dev/null || true)
        if [ -z "$PR_NUMBER" ]; then
            echo "ERROR: no PR found for the current branch — pass --pr N for scenario-name targets."
            exit 1
        fi
    fi
    asset="pr${PR_NUMBER}-$(scenario_dir_name "$target").mp4"
    signed=$(signed_url_for_asset "$RESULTS_REPO" "$RELEASE_TAG" "$asset")
    open_player "$asset" "$signed"
done
```

Then make it executable:

```bash
chmod +x scripts/e2e-watch-video.sh
```

- [ ] **Step 2: Syntax check + help**

```bash
bash -n scripts/e2e-watch-video.sh && ./scripts/e2e-watch-video.sh --help
```

Expected: no syntax errors; usage text prints; exit 0.

- [ ] **Step 3: Verify the asset-name form (with and without .mp4)**

```bash
./scripts/e2e-watch-video.sh pr622-cursor-style-changes
```

Expected: prints `Playing pr622-cursor-style-changes.mp4 (signed URL valid ~1 hour)`; browser tab opens on the player titled `pr622-cursor-style-changes.mp4`; video autoplays and seeks. (Substitute any current asset name if this one was cleaned up — `gh api repos/gpambrozio/ClaudeSpyTestResults/releases/tags/e2e-videos --jq '.assets[].name'`.)

- [ ] **Step 4: Verify the URL form**

```bash
./scripts/e2e-watch-video.sh "https://github.com/gpambrozio/ClaudeSpyTestResults/releases/download/e2e-videos/pr622-cursor-style-changes.mp4"
```

Expected: same as Step 3.

- [ ] **Step 5: Verify the missing-asset error**

```bash
./scripts/e2e-watch-video.sh pr999999-does-not-exist.mp4; echo "exit=$?"
```

Expected: `ERROR: asset 'pr999999-does-not-exist.mp4' not found on release 'e2e-videos' of gpambrozio/ClaudeSpyTestResults.` followed by the indented list of available assets, and `exit=1`.

- [ ] **Step 6: Verify the scenario-name form**

```bash
./scripts/e2e-watch-video.sh --pr 622 "Cursor Style Changes"
```

Expected: resolves to `pr622-cursor-style-changes.mp4` and plays as in Step 3. *Caveat:* pretty scenario names always go remote (form 3 only matches raw paths/dir names, so `cursor-style-changes` with a local recording under the screenshots tmpdir opens the local file, while `"Cursor Style Changes"` resolves the uploaded asset) — that's intended: this script's job is verifying what was uploaded.

- [ ] **Step 7: Commit**

```bash
git add scripts/e2e-watch-video.sh
git commit -m "Add e2e-watch-video.sh: play proof videos in the browser

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Attach-script hint + docs

**Files:**
- Modify: `scripts/e2e-attach-video.sh:14-17` (header note) and `scripts/e2e-attach-video.sh:235` (markdown lines)
- Modify: `docs/e2e-testing.md` (attach section, lines ~235-236, plus a new subsection)

**Interfaces:**
- Consumes: `./scripts/e2e-watch-video.sh <asset-name>` invocation from Task 2.

- [ ] **Step 1: Add the watch hint to the PR comment**

In `scripts/e2e-attach-video.sh`, replace:

```bash
    MARKDOWN_LINES+=("- **▶ [$title]($url)**$(metadata_suffix "$video_dir")")
```

with:

```bash
    MARKDOWN_LINES+=("- **▶ [$title]($url)**$(metadata_suffix "$video_dir")")
    MARKDOWN_LINES+=("  - watch: \`./scripts/e2e-watch-video.sh $asset_name\`")
```

- [ ] **Step 2: Update the attach script's header note**

In `scripts/e2e-attach-video.sh`, replace:

```bash
# Note: release-asset links download the file (GitHub serves them with an
# attachment disposition) rather than playing inline, and require access to
# the results repo.
```

with:

```bash
# Note: release-asset links download the file (GitHub serves them with an
# attachment disposition) rather than playing inline, and require access to
# the results repo. To watch one inline in the browser instead:
#   ./scripts/e2e-watch-video.sh <asset|url|scenario>
```

- [ ] **Step 3: Verify the comment body renders the hint**

```bash
bash -n scripts/e2e-attach-video.sh
```

Expected: exit 0. The hint lines are static strings, so `bash -n` plus reading the diff is sufficient; the next real `e2e-attach-video.sh` run exercises them end-to-end (the nested `- watch:` bullet renders as a sub-item under each video link).

- [ ] **Step 4: Update docs/e2e-testing.md**

Replace the final sentence of the "Attaching a video to a PR" section:

```markdown
gpambrozio/ClaudeSpyTestResults`. Note: release-asset links download rather
than play inline, and require access to the (private) results repo.
```

with:

```markdown
gpambrozio/ClaudeSpyTestResults`. Note: release-asset links download rather
than play inline, and require access to the (private) results repo — use
`e2e-watch-video.sh` (below) to watch one in the browser.

### Watching a video (`e2e-watch-video.sh`)

`./scripts/e2e-watch-video.sh TARGET [TARGET ...]` plays an uploaded proof
video inline in the browser: it resolves the asset's short-lived signed URL
(~1 hour) with your `gh` credentials and opens the static player page
`scripts/e2e-video-player.html` with the URL in the fragment (media loads are
no-cors, so the private asset plays and seeks even though pages can't
`fetch()` it). Each TARGET is an asset name (`pr626-foo[.mp4]`), a
release-asset download URL, a local video file / scenario dir (opened
directly), or a scenario name (`--pr N`, defaulting to the current branch's
PR). `--results-repo` / `--release-tag` override the defaults, as with the
attach script. The attach script's PR comments include a copy-pasteable
`watch:` hint per video.

Design: `docs/superpowers/specs/2026-07-05-e2e-watch-video-design.md`.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/e2e-attach-video.sh docs/e2e-testing.md
git commit -m "Link e2e-watch-video.sh from attach comments and docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
