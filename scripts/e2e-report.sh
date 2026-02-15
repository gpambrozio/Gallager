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
RESULTS_DIR="/tmp/claudespy-test-results"
JSON_OUTPUT="/tmp/e2e-results.json"
SCREENSHOTS_DIR="/tmp/e2e-screenshots"
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
            echo "All e2e-test.sh options (--skip-build, --sim-name, --scenario, etc.)"
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
# RUN E2E TESTS
# =====================================================
step "Running E2E tests"

# Clean screenshots directory
rm -rf "$SCREENSHOTS_DIR"

E2E_EXIT=0
"$SCRIPT_DIR/e2e-test.sh" \
    --screenshots "$SCREENSHOTS_DIR" \
    --json-output "$JSON_OUTPUT" \
    "${E2E_ARGS[@]}" \
    || E2E_EXIT=$?

echo ""
if [ $E2E_EXIT -eq 0 ]; then
    echo "All scenarios passed!"
else
    echo "Some scenarios failed (exit code: $E2E_EXIT)"
fi

# =====================================================
# COLLECT RESULTS INTO REPORT FOLDER
# =====================================================
step "Collecting results"

REPORT_DIR="$RESULTS_DIR/results/$RESULT_FOLDER"
mkdir -p "$REPORT_DIR/screenshots"

# Copy JSON results
if [ -f "$JSON_OUTPUT" ]; then
    cp "$JSON_OUTPUT" "$REPORT_DIR/results.json"
else
    echo "WARNING: No JSON results found — creating empty results."
    echo "[]" > "$REPORT_DIR/results.json"
fi

# Copy screenshots (actual captures + any diff images)
if [ -d "$SCREENSHOTS_DIR" ]; then
    cp -r "$SCREENSHOTS_DIR"/* "$REPORT_DIR/screenshots/" 2>/dev/null || true
fi

# Copy baseline screenshots for side-by-side comparison
if [ -d "$BASELINES_DIR" ]; then
    mkdir -p "$REPORT_DIR/baselines"
    cp -r "$BASELINES_DIR"/* "$REPORT_DIR/baselines/" 2>/dev/null || true
fi

# Build report.json (metadata + scenario results)
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
REPORT_DIR="$REPORT_DIR" \
python3 << 'PYEOF'
import json, os, sys

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
    "allPassed": os.environ["ALL_PASSED"] == "true"
}

report_dir = os.environ["REPORT_DIR"]
results = []
try:
    with open(os.path.join(report_dir, "results.json")) as f:
        results = json.load(f)
except Exception as e:
    print(f"Warning: could not read results.json: {e}", file=sys.stderr)

report = {"metadata": metadata, "scenarios": results}
with open(os.path.join(report_dir, "report.json"), "w") as f:
    json.dump(report, f, indent=2)
print("Report metadata written to report.json")
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

git add results/"$RESULT_FOLDER" results/index.json
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

echo ""
echo "======================================"
echo "  Report complete!"
echo "======================================"
echo "Results folder: $RESULT_FOLDER"
echo "Local path:     $REPORT_DIR"
echo ""

exit $E2E_EXIT
