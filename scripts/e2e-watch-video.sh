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
