#!/bin/bash

# E2E Video Proof Attacher for ClaudeSpy
# Uploads e2e --record videos as ephemeral release assets on the results repo
# and posts a PR comment linking them — video proof that a feature works,
# without committing the video to any repo's git history.
#
# Assets live on a rolling prerelease (default: e2e-videos) of the results
# repo, named pr<N>-<scenario-dir>.mp4, and can be deleted any time after
# review:
#   gh release delete-asset e2e-videos <asset>.mp4 --repo gpambrozio/ClaudeSpyTestResults
# The e2e-video-cleanup.yml workflow deletes them automatically (and marks the
# PR comment) 3 days after the PR merges or closes.
#
# Note: release-asset links download the file (GitHub serves them with an
# attachment disposition) rather than playing inline, and require access to
# the results repo. To watch one inline in the browser instead:
#   ./scripts/e2e-watch-video.sh <asset|url|scenario>

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
PR_NUMBER=""
NO_COMMENT=false
MESSAGE="Recorded with the E2E \`--record\` pipeline:"
LABEL=""
SCENARIOS=()

# =====================================================
# PARSE ARGUMENTS
# =====================================================
usage() {
    echo "Usage: $0 [OPTIONS] SCENARIO [SCENARIO ...]"
    echo ""
    echo "Each SCENARIO is a scenario name (\"Window Description Sync\"), a"
    echo "scenario dir name (window-description-sync), or a path to a video.mp4"
    echo "produced by ./scripts/e2e-test.sh --record."
    echo ""
    echo "Options:"
    echo "  --pr N              PR number to comment on (default: PR for current branch)"
    echo "  --screenshots DIR   Screenshots dir the videos live under"
    echo "                      (default: $SCREENSHOTS_DIR)"
    echo "  --results-repo SLUG owner/repo hosting the release (default: $RESULTS_REPO)"
    echo "  --release-tag TAG   Rolling release tag for assets (default: $RELEASE_TAG)"
    echo "  --no-comment        Upload only; print the markdown snippet instead of"
    echo "                      posting a PR comment"
    echo "  --message TEXT      Custom text above the video links, e.g. what the"
    echo "                      videos prove (markdown; default: \"$MESSAGE\")"
    echo "  --label TEXT        Variant label added to the asset name and link title,"
    echo "                      so two takes of the same scenario don't overwrite each"
    echo "                      other (e.g. --label failing / --label passing for a"
    echo "                      bug-fix repro pair)"
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
        --no-comment)
            NO_COMMENT=true
            shift
            ;;
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --label)
            LABEL="$2"
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
            SCENARIOS+=("$1")
            shift
            ;;
    esac
done

if [ ${#SCENARIOS[@]} -eq 0 ]; then
    echo "ERROR: no scenario given."
    usage
    exit 1
fi

for tool in gh jq python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool is required but not found on PATH."
        exit 1
    fi
done

# =====================================================
# HELPERS
# =====================================================

# Reuse the report pipeline's sanitizer (which is parity-tested against
# TestOrchestrator.scenarioDirName) instead of adding a third copy.
scenario_dir_name() {
    python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
from e2e_report_build import scenario_dir_name
print(scenario_dir_name(sys.argv[2]))
" "$SCRIPT_DIR" "$1"
}

# Resolve a scenario argument to the video.mp4 it names. Accepts a direct
# file path, a scenario dir (path or name under SCREENSHOTS_DIR), or a
# human-readable scenario name.
resolve_video() {
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
    local sanitized
    sanitized=$(scenario_dir_name "$arg")
    if [ -f "$SCREENSHOTS_DIR/$sanitized/video.mp4" ]; then
        echo "$SCREENSHOTS_DIR/$sanitized/video.mp4"
        return 0
    fi
    return 1
}

# Human-readable scenario name: timeline.json records the original name;
# fall back to the caller's argument.
pretty_name() {
    local video_dir="$1" fallback="$2" name=""
    if [ -f "$video_dir/timeline.json" ]; then
        name=$(jq -r '.scenarioName // empty' "$video_dir/timeline.json" 2>/dev/null || true)
    fi
    echo "${name:-$fallback}"
}

# " — 21s (speedup), 135 steps" from video.json, or "" when it's missing.
metadata_suffix() {
    local video_dir="$1"
    [ -f "$video_dir/video.json" ] || return 0
    jq -r '" — \(.durationSeconds | round)s (\(.mode)), \(.steps | length) steps"' \
        "$video_dir/video.json" 2>/dev/null || true
}

# =====================================================
# RESOLVE PR NUMBER
# =====================================================
cd "$PROJECT_ROOT"

if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null || true)
    if [ -z "$PR_NUMBER" ]; then
        echo "ERROR: no PR found for the current branch — pass --pr N."
        exit 1
    fi
fi

# =====================================================
# ENSURE ROLLING RELEASE EXISTS
# =====================================================
if ! gh release view "$RELEASE_TAG" --repo "$RESULTS_REPO" >/dev/null 2>&1; then
    echo "Creating rolling release '$RELEASE_TAG' on $RESULTS_REPO"
    gh release create "$RELEASE_TAG" --repo "$RESULTS_REPO" --prerelease \
        --title "E2E proof videos (ephemeral)" \
        --notes "Rolling container for agent-uploaded E2E proof videos. Assets here are ephemeral: they prove a feature works at PR-review time and may be deleted at any point after merge. Nothing in this release is part of any repo's git history."
fi

# =====================================================
# UPLOAD VIDEOS
# =====================================================
STAGE_DIR=$(mktemp -d -t e2e-attach-video)
trap 'rm -rf "$STAGE_DIR"' EXIT

LABEL_SLUG=""
if [ -n "$LABEL" ]; then
    LABEL_SLUG=$(scenario_dir_name "$LABEL")
fi

MARKDOWN_LINES=()
for scenario in "${SCENARIOS[@]}"; do
    if ! video_path=$(resolve_video "$scenario"); then
        echo "ERROR: no video found for '$scenario'."
        echo "Record one first: ./scripts/e2e-test.sh --record --scenario \"$scenario\""
        exit 1
    fi
    video_dir=$(dirname "$video_path")
    dir_name=$(basename "$video_dir")
    asset_name="pr${PR_NUMBER}-${dir_name}${LABEL_SLUG:+-$LABEL_SLUG}.mp4"

    # gh derives the asset name from the filename, so stage a copy under the
    # target name. --clobber replaces an earlier upload for the same PR+scenario.
    cp "$video_path" "$STAGE_DIR/$asset_name"
    gh release upload "$RELEASE_TAG" "$STAGE_DIR/$asset_name" \
        --repo "$RESULTS_REPO" --clobber
    echo "Uploaded: $asset_name"

    url="https://github.com/$RESULTS_REPO/releases/download/$RELEASE_TAG/$asset_name"
    title="$(pretty_name "$video_dir" "$scenario")${LABEL:+ ($LABEL)}"
    MARKDOWN_LINES+=("- **▶ [$title]($url)**$(metadata_suffix "$video_dir")")
    MARKDOWN_LINES+=("  - watch: \`./scripts/e2e-watch-video.sh $asset_name\`")
done

# =====================================================
# POST PR COMMENT (or print the snippet)
# =====================================================
BODY="## 🎬 E2E Video Proof

$MESSAGE

$(printf '%s\n' "${MARKDOWN_LINES[@]}")

_Ephemeral release asset(s) on ${RESULTS_REPO} (\`${RELEASE_TAG}\` prerelease) — not part of any repo's git history; may be deleted after review._"

if [ "$NO_COMMENT" = true ]; then
    echo ""
    echo "$BODY"
    exit 0
fi

# Post as the bot when its token is available so the comment matches the
# other agent-authored PR traffic; otherwise use the default gh identity.
if [ -n "$BOT_GITHUB_TOKEN" ]; then
    GH_TOKEN="$BOT_GITHUB_TOKEN" gh pr comment "$PR_NUMBER" --body "$BODY"
else
    gh pr comment "$PR_NUMBER" --body "$BODY"
fi
