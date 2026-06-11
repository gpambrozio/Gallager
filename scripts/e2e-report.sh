#!/bin/bash

# E2E Test Report Generator for ClaudeSpy
# Runs all e2e scenarios via e2e-test.sh, collects results + screenshots,
# and pushes a report to the ClaudeSpyTestResults repository.

set -eo pipefail

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_REPO="git@github.com:gpambrozio/ClaudeSpyTestResults.git"
# Anchor to the main worktree's parent so all worktrees share one results clone.
MAIN_WORKTREE_ROOT="$(cd "$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir)/.." && pwd)"
RESULTS_DIR="$(dirname "$MAIN_WORKTREE_ROOT")/ClaudeSpyTestResults"
E2E_TMPDIR="${TMPDIR:-/tmp}/claudespy-e2e"
mkdir -p "$E2E_TMPDIR"
JSON_OUTPUT="$E2E_TMPDIR/e2e-results.json"
SCREENSHOTS_DIR="$E2E_TMPDIR/e2e-screenshots"
BASELINES_DIR="$PROJECT_ROOT/E2ETests"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
DATE_DISPLAY=$(date +"%Y-%m-%d %H:%M:%S")
E2E_ARGS=()

# Use a dedicated DerivedData folder for the report run and wipe it on exit.
# This forces a fresh SPM resolution every report so a stale package checkout
# from another branch (e.g. ProjectNavigator 1.8.0 left over from a different
# PR's build) can't carry into this run. e2e-test.sh already honors
# SANDBOX_DERIVED_DATA as its DerivedData override.
REPORT_DERIVED_DATA="${TMPDIR:-/tmp}/claudespy-e2e-report-derived-data"
export REPORT_DERIVED_DATA
trap 'rm -rf "$REPORT_DERIVED_DATA"' EXIT

# =====================================================
# PARSE ARGUMENTS
# =====================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --results-repo)
            RESULTS_REPO="$2"
            shift 2
            ;;
        --results-dir)
            RESULTS_DIR="$2"
            shift 2
            ;;
        --dashboard-url)
            E2E_ARGS+=(--dashboard-url "$2")
            shift 2
            ;;
        --dashboard-pr-number)
            E2E_ARGS+=(--dashboard-pr-number "$2")
            shift 2
            ;;
        --dashboard-pr-title)
            E2E_ARGS+=(--dashboard-pr-title "$2")
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Runs e2e tests, generates a report, and pushes to the results repository."
            echo ""
            echo "Options:"
            echo "  --results-repo URL  Git URL of the results repository"
            echo "                      (default: $RESULTS_REPO)"
            echo "  --results-dir DIR   Local path for the results repo clone"
            echo "                      (default: $RESULTS_DIR)"
            echo "  -h, --help          Show this help"
            echo ""
            echo "  --dashboard-url URL      Send live CI updates to dashboard (fail-silent)"
            echo "  --dashboard-pr-number N  PR number for dashboard display"
            echo "  --dashboard-pr-title STR PR title for dashboard display"
            echo ""
            echo "All other e2e-test.sh options (--skip-build, --sim-name, --scenario, etc.)"
            echo "are passed through."
            exit 0
            ;;
        *)
            E2E_ARGS+=("$1")
            shift
            ;;
    esac
done

# =====================================================
# HELPERS
# =====================================================
step() {
    echo ""
    echo "======================================"
    echo "  $1"
    echo "======================================"
}

# Rebuild results/index.json from every report.json currently in the working
# tree. Defined as a function (rather than inline) so the push retry below can
# regenerate it after adopting a sibling VM's results during a rebase.
regenerate_index() {
    shopt -s nullglob
    local reports=("$RESULTS_DIR"/results/*/report.json)
    shopt -u nullglob

    if [ ${#reports[@]} -eq 0 ]; then
        echo "[]" > "$RESULTS_DIR/results/index.json"
        echo "Updated index.json with 0 run(s)"
    else
        jq -s 'map({
            folder:          .metadata.folder,
            branch:          .metadata.branch,
            commit:          .metadata.commit,
            commitMessage:   .metadata.commitMessage,
            prNumber:        .metadata.prNumber,
            prUrl:           .metadata.prUrl,
            prTitle:         .metadata.prTitle,
            date:            .metadata.date,
            timestamp:       .metadata.timestamp,
            allPassed:       .metadata.allPassed,
            buildFailed:     .metadata.buildFailed,
            totalScenarios:  (.scenarios | length),
            passedScenarios: ([.scenarios[] | select(.success)] | length),
            failedScenarios: ([.scenarios[] | select(.success | not)] | length)
        }) | sort_by(.timestamp) | reverse' "${reports[@]}" > "$RESULTS_DIR/results/index.json"
        echo "Updated index.json with ${#reports[@]} run(s)"
    fi
}

# =====================================================
# GATHER GIT INFO
# =====================================================
cd "$PROJECT_ROOT"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null || echo "")

# Try to find an associated PR
PR_NUMBER=""
PR_URL=""
PR_TITLE=""
if command -v gh &>/dev/null; then
    PR_INFO=$(gh pr list --head "$BRANCH" --json number,url,title --limit 1 2>/dev/null || echo "[]")
    PR_NUMBER=$(jq -r '.[0].number // ""' <<< "$PR_INFO")
    PR_URL=$(jq -r '.[0].url // ""' <<< "$PR_INFO")
    PR_TITLE=$(jq -r '.[0].title // ""' <<< "$PR_INFO")
fi

SAFE_BRANCH=$(echo "$BRANCH" | sed 's/[^a-zA-Z0-9._-]/-/g')
RESULT_FOLDER="${TIMESTAMP}_${SAFE_BRANCH}"

echo "======================================"
echo "  E2E Test Report Generator"
echo "======================================"
echo "Branch:  $BRANCH"
echo "Commit:  $COMMIT ($COMMIT_MSG)"
if [ -n "$PR_NUMBER" ]; then
    echo "PR:      #$PR_NUMBER ($PR_URL)"
fi
echo "Output:  $RESULT_FOLDER"
echo ""

# =====================================================
# CLONE / UPDATE RESULTS REPOSITORY
# =====================================================
step "Preparing results repository"

# Only ensure a clone exists here. The sync with the remote is deferred until
# right before we write/commit results (see "Syncing results repository" below).
# When many VMs run concurrently, syncing at startup leaves a long window — the
# entire test run — during which a sibling VM can push, so our later push would
# race and fail. Syncing right before the commit keeps that window tiny.
if [ -d "$RESULTS_DIR/.git" ]; then
    echo "Reusing existing clone at $RESULTS_DIR (remote sync deferred until just before commit)"
else
    echo "Cloning results repository to $RESULTS_DIR"
    git clone "$RESULTS_REPO" "$RESULTS_DIR" 2>/dev/null || {
        echo "Clone failed — initializing empty repo"
        mkdir -p "$RESULTS_DIR"
        git -C "$RESULTS_DIR" init
        git -C "$RESULTS_DIR" remote add origin "$RESULTS_REPO" 2>/dev/null || true
    }
fi

# =====================================================
# RUN UNIT TESTS
# =====================================================
step "Running unit tests"

"$SCRIPT_DIR/unit-tests.sh" || {
    echo ""
    echo "Unit tests failed — aborting e2e run."
    exit 1
}

# =====================================================
# RUN E2E TESTS
# =====================================================

# Clean stale results from previous runs to prevent reporting old data
rm -f "$JSON_OUTPUT"
rm -rf "$SCREENSHOTS_DIR"

step "Running E2E tests"

E2E_EXIT=0
"$SCRIPT_DIR/e2e-test.sh" \
    --screenshots "$SCREENSHOTS_DIR" \
    --json-output "$JSON_OUTPUT" \
    "${E2E_ARGS[@]}" \
    || E2E_EXIT=$?

# Detect build failure vs test failure:
# If the exit code is non-zero and no JSON was produced, the build failed
# before the test coordinator could run.
BUILD_FAILED=false
if [ $E2E_EXIT -ne 0 ] && [ ! -f "$JSON_OUTPUT" ]; then
    BUILD_FAILED=true
fi

echo ""
if [ "$BUILD_FAILED" = true ]; then
    echo "Build failed (no test results produced, exit code: $E2E_EXIT)"
elif [ $E2E_EXIT -eq 0 ]; then
    echo "All scenarios passed!"
else
    echo "Some scenarios failed (exit code: $E2E_EXIT)"
fi

# =====================================================
# SYNC RESULTS REPO WITH REMOTE (just before we write into it)
# =====================================================
# Adopt the latest remote state now — after the long test run, immediately
# before we start writing results. Nothing of ours is in the working tree yet,
# so a hard reset is safe and gives us a clean, up-to-date base. This is the
# narrowest possible window before the commit/push, which keeps concurrent VM
# runs from clobbering each other.
step "Syncing results repository"

if git -C "$RESULTS_DIR" remote get-url origin &>/dev/null && \
   git -C "$RESULTS_DIR" fetch origin 2>/dev/null; then
    if git -C "$RESULTS_DIR" rev-parse --verify origin/main &>/dev/null; then
        git -C "$RESULTS_DIR" checkout main 2>/dev/null \
            || git -C "$RESULTS_DIR" checkout -b main 2>/dev/null || true
        git -C "$RESULTS_DIR" reset --hard origin/main 2>/dev/null || true
        echo "Synced to origin/main"
    else
        echo "No origin/main on remote yet — our push will create it"
    fi
else
    echo "Could not reach remote — proceeding with local-only results"
fi

# =====================================================
# COLLECT RESULTS INTO REPORT FOLDER
# =====================================================
step "Collecting results"

IMAGES_DIR="$RESULTS_DIR/images"
mkdir -p "$IMAGES_DIR"

REPORT_DIR="$RESULTS_DIR/results/$RESULT_FOLDER"
mkdir -p "$REPORT_DIR"

# Copy JSON results
if [ -f "$JSON_OUTPUT" ]; then
    cp "$JSON_OUTPUT" "$REPORT_DIR/results.json"
else
    echo "WARNING: No JSON results found — creating empty results."
    echo "[]" > "$REPORT_DIR/results.json"
fi

# Build report.json (metadata + scenario results with content-addressed images)
ALL_PASSED=$( [ $E2E_EXIT -eq 0 ] && echo "true" || echo "false" )
BRANCH="$BRANCH" \
COMMIT="$COMMIT" \
COMMIT_FULL="$COMMIT_FULL" \
COMMIT_MSG="$COMMIT_MSG" \
PR_NUMBER="$PR_NUMBER" \
PR_URL="$PR_URL" \
PR_TITLE="$PR_TITLE" \
TIMESTAMP="$TIMESTAMP" \
DATE_DISPLAY="$DATE_DISPLAY" \
RESULT_FOLDER="$RESULT_FOLDER" \
ALL_PASSED="$ALL_PASSED" \
BUILD_FAILED="$BUILD_FAILED" \
REPORT_DIR="$REPORT_DIR" \
IMAGES_DIR="$IMAGES_DIR" \
SCREENSHOTS_DIR="$SCREENSHOTS_DIR" \
BASELINES_DIR="$BASELINES_DIR" \
python3 << 'PYEOF'
import json, os, sys, hashlib, shutil

metadata = {
    "branch": os.environ["BRANCH"],
    "commit": os.environ["COMMIT"],
    "commitFull": os.environ["COMMIT_FULL"],
    "commitMessage": os.environ["COMMIT_MSG"],
    "prNumber": os.environ["PR_NUMBER"] or None,
    "prUrl": os.environ["PR_URL"] or None,
    "prTitle": os.environ["PR_TITLE"] or None,
    "timestamp": os.environ["TIMESTAMP"],
    "date": os.environ["DATE_DISPLAY"],
    "folder": os.environ["RESULT_FOLDER"],
    "allPassed": os.environ["ALL_PASSED"] == "true",
    "buildFailed": os.environ["BUILD_FAILED"] == "true"
}

report_dir = os.environ["REPORT_DIR"]
images_dir = os.environ["IMAGES_DIR"]
screenshots_dir = os.environ["SCREENSHOTS_DIR"]
baselines_dir = os.environ["BASELINES_DIR"]

def store_image(src_path):
    """Compute SHA-256, copy to images/<hash>.png if not present, return hash."""
    if not src_path or not os.path.isfile(src_path):
        return None
    h = hashlib.sha256()
    with open(src_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    sha = h.hexdigest()
    dest = os.path.join(images_dir, f"{sha}.png")
    if not os.path.exists(dest):
        shutil.copy2(src_path, dest)
    return sha

def process_screenshot(ss):
    """Convert a path-based screenshot dict to hash-based fields."""
    label = ss.get("label", "")
    passed = ss.get("passed", True)
    baseline_created = ss.get("baselineCreated", False)
    diff_percentage = ss.get("diffPercentage")

    # Resolve source paths
    actual_path = ss.get("actualPath") or os.path.join(screenshots_dir, f"{label}.png")
    baseline_path = ss.get("baselinePath") or os.path.join(baselines_dir, f"{label}.png")
    diff_path = ss.get("diffPath")

    actual_hash = store_image(actual_path)
    baseline_hash = store_image(baseline_path)
    diff_hash = store_image(diff_path) if diff_path else None

    if passed and not baseline_created and diff_percentage is not None:
        # Passed comparison — use baseline hash as imageHash
        image_hash = baseline_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = None
    elif not passed:
        # Failed comparison
        image_hash = actual_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = diff_hash
    elif baseline_created:
        # Baseline created
        image_hash = actual_hash
        result_baseline_hash = actual_hash
        result_diff_hash = None
    else:
        # No comparison (passed, no baseline created, no diff percentage)
        image_hash = actual_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = None

    return {
        "label": label,
        "imageHash": image_hash,
        "baselineHash": result_baseline_hash,
        "diffHash": result_diff_hash,
        "diffPercentage": diff_percentage,
        "passed": passed,
        "baselineCreated": baseline_created,
    }

def process_failure_screenshot(fs):
    """Convert a path-based failure screenshot dict to a hash-based field."""
    target = fs.get("target", "")
    path = fs.get("path")
    image_hash = store_image(path) if path else None
    return {
        "target": target,
        "imageHash": image_hash,
    }

results = []
try:
    with open(os.path.join(report_dir, "results.json")) as f:
        results = json.load(f)
except Exception as e:
    print(f"Warning: could not read results.json: {e}", file=sys.stderr)

# Process screenshot + failure screenshots in each scenario's steps
for scenario in results:
    for step in scenario.get("steps", []):
        ss = step.get("screenshot")
        if ss:
            step["screenshot"] = process_screenshot(ss)
        failures = step.get("failureScreenshots") or []
        if failures:
            step["failureScreenshots"] = [
                process_failure_screenshot(f) for f in failures
            ]

report = {"metadata": metadata, "scenarios": results}
with open(os.path.join(report_dir, "report.json"), "w") as f:
    json.dump(report, f, indent=2)

image_count = len(os.listdir(images_dir)) if os.path.isdir(images_dir) else 0
print(f"Report written to report.json ({image_count} images in content-addressed store)")
PYEOF

# =====================================================
# UPDATE RESULTS INDEX
# =====================================================
step "Updating results index"

regenerate_index

# =====================================================
# COMMIT AND PUSH TO RESULTS REPO
# =====================================================
step "Pushing results to repository"

cd "$RESULTS_DIR"

git add results/"$RESULT_FOLDER" results/index.json images/
git commit -m "E2E results: ${SAFE_BRANCH} @ ${COMMIT} (${TIMESTAMP})

Branch: ${BRANCH}
Commit: ${COMMIT_FULL}
$([ -n "$PR_NUMBER" ] && echo "PR: #${PR_NUMBER}" || echo "")" || {
    echo "Nothing to commit"
}

# Push, retrying if a sibling VM pushed in the small window since we synced.
# Our report folder is uniquely named and images are content-addressed, so the
# only file that can conflict on rebase is results/index.json — which we resolve
# by regenerating it from the now-merged set of reports.
PUSH_OK=false
for attempt in 1 2 3 4 5; do
    if git push origin HEAD 2>&1; then
        PUSH_OK=true
        break
    fi

    echo "Push rejected (attempt ${attempt}/5) — a sibling run pushed first; rebasing onto latest"
    git fetch origin 2>/dev/null || true

    if git rebase origin/main 2>/dev/null; then
        continue
    fi

    echo "Resolving results/index.json conflict by regeneration"
    regenerate_index
    git add results/index.json
    if ! GIT_EDITOR=true git rebase --continue 2>/dev/null; then
        echo "WARNING: could not rebase cleanly onto remote — aborting rebase"
        git rebase --abort 2>/dev/null || true
        break
    fi
done

if [ "$PUSH_OK" != true ]; then
    # First-ever push (no upstream branch) or a genuine failure.
    REMOTE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if git push -u origin "$REMOTE_BRANCH" 2>/dev/null; then
        PUSH_OK=true
    else
        echo "WARNING: Failed to push to remote. Results saved locally at $RESULTS_DIR"
    fi
fi

# =====================================================
# POST PR COMMENT (on failure only)
# =====================================================
if [ -n "$PR_NUMBER" ] && command -v gh &>/dev/null; then
    step "Posting PR comment"

    # Build scenario summary from results JSON
    SCENARIO_SUMMARY=$(jq -r '
        .scenarios
        | map("| " + (if .success then "\u2705" else "\u274c" end) + " | " + (.scenarioName // "unknown") + " |")
        | join("\n")
    ' "$REPORT_DIR/report.json" 2>/dev/null) || SCENARIO_SUMMARY="| \u26a0\ufe0f | Could not parse results |"

    if [ "$BUILD_FAILED" = true ]; then
        COMMENT_TITLE="## E2E Build Failure"
        SCENARIO_SUMMARY="| :no_entry: | Build failed — no tests ran |"
    elif [ $E2E_EXIT -eq 0 ]; then
        COMMENT_TITLE="## E2E Tests Passed"
    else
        COMMENT_TITLE="## E2E Test Failure"
    fi

    cd "$PROJECT_ROOT"
    gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
${COMMENT_TITLE}

| Status | Scenario |
|--------|----------|
${SCENARIO_SUMMARY}

**Commit:** \`${COMMIT}\` ${COMMIT_MSG}
**Branch:** ${BRANCH}
EOF
    )" && echo "PR comment posted to #${PR_NUMBER}" || echo "WARNING: Failed to post PR comment"
fi

echo ""
echo "======================================"
echo "  Report complete!"
echo "======================================"
echo "Results folder: $RESULT_FOLDER"
echo "Local path:     $REPORT_DIR"
echo ""

exit $E2E_EXIT
