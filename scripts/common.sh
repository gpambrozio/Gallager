#!/bin/bash

# Shared helpers for the ClaudeSpy release scripts (release.sh, testflight.sh).
# Source this file after computing SCRIPT_DIR and defining CONFIG_FILE (and,
# for generate_changelog, PROJECT_ROOT):
#
#   source "$SCRIPT_DIR/common.sh"
#
# It only defines colors, logging, version lookups, the notes editor, and the
# iOS changelog generator — it does not set shell options or run anything at
# source time, so it is safe to source early.

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

# =====================================================
# Generate TestFlight "What to Test" notes with Claude.
# Requires PROJECT_ROOT to be set by the caller.
#
# Args:
#   $1 version   - marketing version to reference in the notes
#                  (defaults to get_version)
#   $2 prev_tag  - previous release tag to diff against. If empty, the most
#                  recent tag that is NOT $version is used. Pass this
#                  explicitly when generating notes BEFORE the release tag
#                  exists (e.g. release.sh gathers them up front).
#
# Prints the notes to stdout; all logging goes to stderr.
# =====================================================
generate_changelog() {
    local version="${1:-$(get_version)}"
    local prev_tag="$2"

    if [ -z "$prev_tag" ]; then
        prev_tag=$(git -C "$PROJECT_ROOT" tag --sort=-v:refname \
            | grep -Ev "^v?${version}$" \
            | head -1)
    fi

    local commit_range
    if [ -z "$prev_tag" ]; then
        log_warning "No previous tag found, using last 20 commits" >&2
        commit_range="HEAD~20..HEAD"
    else
        log_info "Generating changelog since $prev_tag" >&2
        commit_range="${prev_tag}..HEAD"
    fi

    local commits
    commits=$(git -C "$PROJECT_ROOT" log "$commit_range" --pretty=format:"- %s (%h)" --no-merges 2>/dev/null || echo "Initial release")

    if ! command -v claude &> /dev/null; then
        log_warning "Claude CLI not found, using raw commit list" >&2
        echo "$commits"
        return
    fi

    log_info "Generating What to Test notes with Claude..." >&2

    local prompt="You are a technical writer creating TestFlight 'What to Test' notes for testers.

Generate concise, tester-friendly notes for version $version of Gallager (ClaudeSpy), an iOS app for remotely monitoring Claude Code sessions.

IMPORTANT: This is an independent open source project. It is NOT affiliated with or built by Anthropic.

Here are the commits since the last release:
$commits

Requirements:
- ONLY include changes that directly affect the user experience on iOS (new features, behavior changes, bug fixes users would notice, performance improvements)
- ONLY include changes from shared layers (networking, encryption, server relay) if they have a visible effect on the iOS app
- SKIP anything that does not affect users: CI/CD changes, build scripts, internal refactoring, code cleanup, dependency updates, tests, docs, tooling, release scripts, macOS-only changes, server infrastructure changes invisible to users
- If a commit is ambiguous, err on the side of omitting it
- Group changes by category (New Features, Improvements, Bug Fixes) if applicable
- Explain what each change means for testers — what to look for, what might break
- Keep it concise but informative — this is TestFlight, not a press release
- Use plain text, no markdown (TestFlight renders plain text only)
- Do NOT wrap output in code fences, backticks, or any formatting wrappers
- Do NOT include ANY preamble, commentary, thinking, or meta-text — start directly with the content
- Do NOT add URLs, links, or 'for more information' sections
- Output ONLY the What to Test content itself
- If no user-facing iOS changes exist, output: No user-facing changes in this build."

    local notes
    notes=$(claude -p "$prompt" 2>/dev/null) || {
        log_warning "Claude failed to generate notes, using raw commit list" >&2
        echo "$commits"
        return
    }

    # Strip code fences in case Claude ignored the instruction to omit them
    notes=$(echo "$notes" | sed '/^```/d')

    echo "$notes"
}
