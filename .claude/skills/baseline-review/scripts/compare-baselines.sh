#!/bin/bash
# Compare E2E baseline images between current branch and main using ImageMagick.
# Outputs a JSON report categorizing each image as: new, dithering, or changed.
# For changed images, generates diff images highlighting differences in red.
#
# Usage: compare-baselines.sh [--fuzz PERCENT] [--threshold PERCENT] [--output-dir DIR]
#   --fuzz        Per-pixel color tolerance for ImageMagick (default: 5%)
#   --threshold   Maximum % of differing pixels to consider "dithering only" (default: 0.1%)
#   --output-dir  Directory for diff images and main-branch extracts (default: /tmp/baseline-review)
#
# Requires: git, ImageMagick 7 (magick compare)

set -euo pipefail

FUZZ="5%"
THRESHOLD="0.001"  # 0.1% of pixels
OUTPUT_DIR="/tmp/baseline-review"

while [[ $# -gt 0 ]]; do
    case $1 in
        --fuzz) FUZZ="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Create output directories
mkdir -p "$OUTPUT_DIR/main" "$OUTPUT_DIR/diff"

INTERNAL_TMP=$(mktemp -d)
trap "rm -rf $INTERNAL_TMP" EXIT

BASE_BRANCH="main"

# Find all changed PNG files in E2ETests/
NEW_FILES=$(git diff --diff-filter=A --name-only "$BASE_BRANCH" -- 'E2ETests/**/*.png' 2>/dev/null || true)
MODIFIED_FILES=$(git diff --diff-filter=M --name-only "$BASE_BRANCH" -- 'E2ETests/**/*.png' 2>/dev/null || true)
DELETED_FILES=$(git diff --diff-filter=D --name-only "$BASE_BRANCH" -- 'E2ETests/**/*.png' 2>/dev/null || true)

echo "{"
echo "  \"output_dir\": \"$OUTPUT_DIR\","

# New files
echo '  "new": ['
first=true
while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ "$first" = true ] && first=false || echo ","
    printf '    "%s"' "$f"
done <<< "$NEW_FILES"
echo ""
echo "  ],"

# Deleted files
echo '  "deleted": ['
first=true
while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ "$first" = true ] && first=false || echo ","
    printf '    "%s"' "$f"
done <<< "$DELETED_FILES"
echo ""
echo "  ],"

# Modified files — compare each
dithering_files=()
changed_files=()
changed_pcts=()
changed_safe_names=()

while IFS= read -r f; do
    [ -z "$f" ] && continue

    # Create a safe filename from the path
    safe_name=$(echo "$f" | sed 's|E2ETests/||' | tr '/' '__')

    # Extract main version to output directory
    main_file="$OUTPUT_DIR/main/$safe_name"
    if ! git show "${BASE_BRANCH}:${f}" > "$main_file" 2>/dev/null; then
        continue
    fi

    # Compare with ImageMagick — get absolute error (pixel count) and percentage
    result=$(magick compare -metric AE -fuzz "$FUZZ" "$f" "$main_file" null: 2>&1 || true)

    # Parse the result — format is "COUNT (PERCENTAGE)"
    pct=$(echo "$result" | grep -oE '\([0-9.e+-]+\)' | tr -d '()')

    if [ -z "$pct" ]; then
        changed_files+=("$f")
        changed_pcts+=("unknown")
        changed_safe_names+=("$safe_name")
        # Generate diff image anyway
        magick compare -highlight-color red -lowlight-color 'rgba(255,255,255,0.15)' -fuzz "$FUZZ" "$f" "$main_file" "$OUTPUT_DIR/diff/$safe_name" 2>/dev/null || true
        continue
    fi

    is_dithering=$(echo "$pct <= $THRESHOLD" | bc -l 2>/dev/null || echo "0")

    if [ "$is_dithering" = "1" ]; then
        dithering_files+=("$f")
        # No diff image needed for dithering
        rm -f "$main_file"  # Clean up main version too
    else
        changed_files+=("$f")
        changed_pcts+=("$pct")
        changed_safe_names+=("$safe_name")
        # Generate diff image with red highlights on differences
        magick compare -highlight-color red -lowlight-color 'rgba(255,255,255,0.15)' -fuzz "$FUZZ" "$f" "$main_file" "$OUTPUT_DIR/diff/$safe_name" 2>/dev/null || true
    fi
done <<< "$MODIFIED_FILES"

# Output dithering files
echo '  "dithering": ['
first=true
for f in "${dithering_files[@]+"${dithering_files[@]}"}"; do
    [ "$first" = true ] && first=false || echo ","
    printf '    "%s"' "$f"
done
echo ""
echo "  ],"

# Output changed files with diff percentages and paths to diff images
echo '  "changed": ['
first=true
for i in "${!changed_files[@]}"; do
    [ "$first" = true ] && first=false || echo ","
    printf '    {"file": "%s", "diff_pct": "%s", "safe_name": "%s", "diff_image": "%s/diff/%s", "main_image": "%s/main/%s"}' \
        "${changed_files[$i]}" "${changed_pcts[$i]}" "${changed_safe_names[$i]}" \
        "$OUTPUT_DIR" "${changed_safe_names[$i]}" "$OUTPUT_DIR" "${changed_safe_names[$i]}"
done
echo ""
echo "  ],"

# Summary
echo "  \"summary\": {"
echo "    \"new\": $(echo "$NEW_FILES" | grep -c . || echo 0),"
echo "    \"deleted\": $(echo "$DELETED_FILES" | grep -c . || echo 0),"
echo "    \"dithering\": ${#dithering_files[@]},"
echo "    \"changed\": ${#changed_files[@]}"
echo "  }"

echo "}"
