#!/bin/bash

# Record a tmux session for E2E test replay
# Captures terminal content (with ANSI escape codes) from a running tmux pane.
#
# Usage:
#   ./scripts/record-tmux-session.sh [--name <recording-name>] [--snapshot] [--pipe-only]
#
# Modes:
#   Default (streaming): Captures initial state + live output until you press Enter
#   --snapshot:          Captures only the current scrollback + visible content
#   --pipe-only:         Captures only live pipe-pane output (no initial capture-pane)
#
# Output: E2ETests/Recordings/<name>/
#   metadata.json  — pane dimensions
#   recording.data — terminal content (single file, ANSI codes preserved)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RECORDINGS_DIR="$PROJECT_ROOT/E2ETests/Recordings"

NAME=""
SNAPSHOT=false
PIPE_ONLY=false

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
        --pipe-only)
            PIPE_ONLY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--name <recording-name>] [--snapshot] [--pipe-only]"
            echo ""
            echo "Options:"
            echo "  --name       Name for the recording (prompted if omitted)"
            echo "  --snapshot   Capture only current state (no streaming)"
            echo "  --pipe-only  Capture only live output (no initial capture-pane)"
            echo "  -h, --help   Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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

# Prompt for name if not provided via flag
if [[ -z "$NAME" ]]; then
    read -rp "Recording name: " NAME
    if [[ -z "$NAME" ]]; then
        echo "Error: name cannot be empty"
        exit 1
    fi
fi

# Get pane dimensions
DIMS=$(tmux display-message -t "$TARGET" -p "#{pane_width} #{pane_height}")
WIDTH=$(echo "$DIMS" | awk '{print $1}')
HEIGHT=$(echo "$DIMS" | awk '{print $2}')
echo "Dimensions: ${WIDTH}x${HEIGHT}"

# Create output directory
OUTPUT_DIR="$RECORDINGS_DIR/$NAME"
mkdir -p "$OUTPUT_DIR"

if [[ "$SNAPSHOT" == true ]]; then
    # Snapshot: capture-pane only, no streaming
    echo "Capturing pane content (snapshot)..."
    tmux capture-pane -t "$TARGET" -p -e -S - > "$OUTPUT_DIR/recording.data"
elif [[ "$PIPE_ONLY" == true ]]; then
    # Pipe-only: raw bytes only, no initial capture-pane
    echo "Recording raw pipe output only..."
    : > "$OUTPUT_DIR/recording.data"
    tmux pipe-pane -t "$TARGET" -o "cat >> '$OUTPUT_DIR/recording.data'"
    echo "Recording live output... Press Enter to stop."
    read -r
    tmux pipe-pane -t "$TARGET"
else
    # Default: capture initial state + live output
    echo "Capturing pane content..."
    tmux capture-pane -t "$TARGET" -p -e -S - > "$OUTPUT_DIR/recording.data"
    tmux pipe-pane -t "$TARGET" -o "cat >> '$OUTPUT_DIR/recording.data'"
    echo "Recording live output... Press Enter to stop."
    read -r
    tmux pipe-pane -t "$TARGET"
fi

# Write metadata
cat > "$OUTPUT_DIR/metadata.json" <<EOF
{"width": $WIDTH, "height": $HEIGHT}
EOF

echo ""
echo "Recording saved to: $OUTPUT_DIR/"
echo "  metadata.json   — ${WIDTH}x${HEIGHT}"
echo "  recording.data  — $(wc -c < "$OUTPUT_DIR/recording.data") bytes"
