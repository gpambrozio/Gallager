#!/bin/bash

# Record a tmux session for E2E test replay
# Captures terminal content (with ANSI escape codes) from a running tmux pane.
#
# Usage:
#   ./scripts/record-tmux-session.sh --name <recording-name> [--snapshot]
#
# Modes:
#   Default (streaming): Captures initial state + live output until you press Enter
#   --snapshot:          Captures only the current scrollback + visible content

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RECORDINGS_DIR="$PROJECT_ROOT/E2ETests/Recordings"

NAME=""
SNAPSHOT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            NAME="$2"
            shift 2
            ;;
        --snapshot)
            SNAPSHOT=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --name <recording-name> [--snapshot]"
            echo ""
            echo "Options:"
            echo "  --name       Name for the recording (required)"
            echo "  --snapshot   Capture only current state (no streaming)"
            echo "  -h, --help   Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "Error: --name is required"
    echo "Usage: $0 --name <recording-name> [--snapshot]"
    exit 1
fi

# Verify tmux is running
if ! tmux list-sessions &>/dev/null; then
    echo "Error: No tmux sessions found. Start a tmux session first."
    exit 1
fi

# List all panes
echo "Available tmux panes:"
echo "---"
PANES=()
INDEX=0
while IFS= read -r line; do
    PANES+=("$line")
    echo "  [$INDEX] $line"
    ((INDEX++)) || true
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}  #{pane_width}x#{pane_height}  #{pane_current_command}")
echo "---"

if [[ ${#PANES[@]} -eq 0 ]]; then
    echo "Error: No tmux panes found."
    exit 1
fi

# User selects a pane
read -rp "Select pane number [0-$((${#PANES[@]} - 1))]: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [[ "$SELECTION" -ge ${#PANES[@]} ]]; then
    echo "Error: Invalid selection"
    exit 1
fi

# Extract target from selected pane (first field)
TARGET=$(echo "${PANES[$SELECTION]}" | awk '{print $1}')
echo "Selected: $TARGET"

# Get pane dimensions
DIMS=$(tmux display-message -t "$TARGET" -p "#{pane_width} #{pane_height}")
WIDTH=$(echo "$DIMS" | awk '{print $1}')
HEIGHT=$(echo "$DIMS" | awk '{print $2}')
echo "Dimensions: ${WIDTH}x${HEIGHT}"

# Create output directory
OUTPUT_DIR="$RECORDINGS_DIR/$NAME"
mkdir -p "$OUTPUT_DIR"

# Capture initial state (scrollback + visible, with ANSI escape codes)
echo "Capturing pane content..."
tmux capture-pane -t "$TARGET" -p -e -S - > "$OUTPUT_DIR/content.data"

if [[ "$SNAPSHOT" == true ]]; then
    echo "Snapshot mode — skipping stream capture."
else
    # Start live capture
    STREAM_TMP="/tmp/claudespy-recording-stream-$$.data"
    tmux pipe-pane -t "$TARGET" -o "cat >> '$STREAM_TMP'"
    echo "Recording live output... Press Enter to stop."
    read -r

    # Stop piping
    tmux pipe-pane -t "$TARGET"

    if [[ -f "$STREAM_TMP" ]]; then
        mv "$STREAM_TMP" "$OUTPUT_DIR/stream.data"
        echo "Stream captured: $(wc -c < "$OUTPUT_DIR/stream.data") bytes"
    else
        echo "No stream data captured."
    fi
fi

# Write metadata
cat > "$OUTPUT_DIR/metadata.json" <<EOF
{"width": $WIDTH, "height": $HEIGHT}
EOF

echo ""
echo "Recording saved to: $OUTPUT_DIR/"
echo "  metadata.json  — ${WIDTH}x${HEIGHT}"
echo "  content.data   — $(wc -c < "$OUTPUT_DIR/content.data") bytes"
if [[ -f "$OUTPUT_DIR/stream.data" ]]; then
    echo "  stream.data    — $(wc -c < "$OUTPUT_DIR/stream.data") bytes"
fi
