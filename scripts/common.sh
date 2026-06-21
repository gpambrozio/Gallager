#!/bin/bash

# Shared helpers for the ClaudeSpy release scripts (release.sh, testflight.sh).
# Source this file after computing SCRIPT_DIR and defining CONFIG_FILE:
#
#   source "$SCRIPT_DIR/common.sh"
#
# It only defines colors, logging, version lookups, and the notes editor — it
# does not set shell options or run anything, so it is safe to source early.

# =====================================================
# Colors for output
# =====================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =====================================================
# Logging
# =====================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }  # exits

# =====================================================
# Version helpers (require CONFIG_FILE to be set by the caller)
# =====================================================
get_version() {
    grep "^MARKETING_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' '
}

get_build_number() {
    grep "^CURRENT_PROJECT_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' '
}

# =====================================================
# Offer to edit generated notes in $VISUAL / $EDITOR
# Sets the edited (or original) text in EDITED_NOTES.
# =====================================================
EDITED_NOTES=""
offer_to_edit_notes() {
    local notes="$1"
    local label="$2"
    local filename="$3"

    EDITED_NOTES="$notes"

    read -p "Do you want to edit the $label before continuing? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi

    local editor="${VISUAL:-${EDITOR:-vi}}"

    local tmp_dir
    tmp_dir=$(mktemp -d) || {
        log_warning "Could not create a temp directory — skipping edit"
        return
    }
    local tmp_file="$tmp_dir/$filename"

    printf '%s\n' "$notes" > "$tmp_file"

    # Open the editor and wait for it to close, then read the result back.
    if ! $editor "$tmp_file"; then
        log_warning "Editor exited with a non-zero status — using the saved file contents"
    fi

    EDITED_NOTES=$(cat "$tmp_file")
    rm -rf "$tmp_dir"

    log_success "Using edited $label"
}
