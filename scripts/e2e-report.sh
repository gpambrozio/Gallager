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
RESULTS_DIR="$(cd "$PROJECT_ROOT/.." && pwd)/ClaudeSpyTestResults"
E2E_TMPDIR="${TMPDIR:-/tmp}/claudespy-e2e"
mkdir -p "$E2E_TMPDIR"
JSON_OUTPUT="$E2E_TMPDIR/e2e-results.json"
SCREENSHOTS_DIR="$E2E_TMPDIR/e2e-screenshots"
BASELINES_DIR="$PROJECT_ROOT/E2ETests"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
DATE_DISPLAY=$(date +"%Y-%m-%d %H:%M:%S")
E2E_ARGS=()

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
if command -v gh &>/dev/null; then
    PR_INFO=$(gh pr list --head "$BRANCH" --json number,url --limit 1 2>/dev/null || echo "[]")
    PR_NUMBER=$(echo "$PR_INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['number'] if d else '')" 2>/dev/null || echo "")
    PR_URL=$(echo "$PR_INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['url'] if d else '')" 2>/dev/null || echo "")
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

if [ -d "$RESULTS_DIR/.git" ]; then
    echo "Updating existing clone at $RESULTS_DIR"
    if ! git -C "$RESULTS_DIR" pull --rebase 2>&1; then
        echo "WARNING: pull --rebase failed — resetting to remote state"
        git -C "$RESULTS_DIR" fetch origin 2>/dev/null
        git -C "$RESULTS_DIR" reset --hard origin/main 2>/dev/null || true
    fi
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

results = []
try:
    with open(os.path.join(report_dir, "results.json")) as f:
        results = json.load(f)
except Exception as e:
    print(f"Warning: could not read results.json: {e}", file=sys.stderr)

# Process screenshot in each scenario's steps
for scenario in results:
    for step in scenario.get("steps", []):
        ss = step.get("screenshot")
        if ss:
            step["screenshot"] = process_screenshot(ss)

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

RESULTS_DIR="$RESULTS_DIR" python3 << 'PYEOF'
import json, os, glob

results_base = os.path.join(os.environ["RESULTS_DIR"], "results")
runs = []

for report_file in sorted(glob.glob(os.path.join(results_base, "*/report.json")), reverse=True):
    try:
        with open(report_file) as f:
            report = json.load(f)
        meta = report.get("metadata", {})
        scenarios = report.get("scenarios", [])
        total = len(scenarios)
        passed = sum(1 for s in scenarios if s.get("success", False))
        runs.append({
            "folder": meta.get("folder", os.path.basename(os.path.dirname(report_file))),
            "branch": meta.get("branch", "unknown"),
            "commit": meta.get("commit", "unknown"),
            "commitMessage": meta.get("commitMessage", ""),
            "prNumber": meta.get("prNumber"),
            "prUrl": meta.get("prUrl"),
            "date": meta.get("date", ""),
            "timestamp": meta.get("timestamp", ""),
            "allPassed": meta.get("allPassed", False),
            "buildFailed": meta.get("buildFailed", False),
            "totalScenarios": total,
            "passedScenarios": passed,
            "failedScenarios": total - passed,
        })
    except Exception as e:
        print(f"Warning: Failed to read {report_file}: {e}")

with open(os.path.join(results_base, "index.json"), "w") as f:
    json.dump(runs, f, indent=2)
print(f"Updated index.json with {len(runs)} run(s)")
PYEOF

# =====================================================
# COMMIT AND PUSH TO RESULTS REPO
# =====================================================
step "Pushing results to repository"

cd "$RESULTS_DIR"

git fetch origin 2>/dev/null || true
git rebase origin/main 2>/dev/null || true

git add results/"$RESULT_FOLDER" results/index.json images/
git commit -m "E2E results: ${SAFE_BRANCH} @ ${COMMIT} (${TIMESTAMP})

Branch: ${BRANCH}
Commit: ${COMMIT_FULL}
$([ -n "$PR_NUMBER" ] && echo "PR: #${PR_NUMBER}" || echo "")" || {
    echo "Nothing to commit"
}

git push origin HEAD 2>/dev/null || {
    REMOTE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    git push -u origin "$REMOTE_BRANCH" 2>/dev/null || {
        echo "WARNING: Failed to push to remote. Results saved locally at $RESULTS_DIR"
    }
}

# =====================================================
# POST PR COMMENT (on failure only)
# =====================================================
if [ -n "$PR_NUMBER" ] && command -v gh &>/dev/null; then
    step "Posting PR comment"

    # Build scenario summary from results JSON
    SCENARIO_SUMMARY=$(REPORT_DIR="$REPORT_DIR" python3 << 'PYEOF'
import json, os

report_dir = os.environ["REPORT_DIR"]
try:
    with open(os.path.join(report_dir, "report.json")) as f:
        report = json.load(f)
    lines = []
    for s in report.get("scenarios", []):
        icon = "\u2705" if s.get("success") else "\u274c"
        name = s.get("scenarioName", "unknown")
        lines.append(f"| {icon} | {name} |")
    print("\n".join(lines))
except Exception:
    print("| \u26a0\ufe0f | Could not parse results |")
PYEOF
    )

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
