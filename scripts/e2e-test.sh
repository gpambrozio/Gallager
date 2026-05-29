#!/bin/bash

# E2E Test Script for ClaudeSpy
# Builds all targets and runs the E2E test coordinator

set -eo pipefail

# Add Homebrew to PATH if not already present (needed on CI VMs)
if [[ ":$PATH:" != *":/opt/homebrew/bin:"* ]] && [ -d /opt/homebrew/bin ]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

# Unlock the login keychain so codesign can access signing certificates in SSH/CI sessions.
# Uses KEYCHAIN_PASSWORD env var if set, otherwise tries the default CI password.
if [ -f ~/Library/Keychains/login.keychain-db ]; then
    security unlock-keychain -p "${KEYCHAIN_PASSWORD:-admin}" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
fi

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$PROJECT_ROOT/ClaudeSpy.xcworkspace"
_E2E_DD_DEFAULT="${TMPDIR:-/tmp}/claudespy-e2e-derived-data"
DERIVED_DATA="${REPORT_DERIVED_DATA:-${SANDBOX_DERIVED_DATA:-$_E2E_DD_DEFAULT}}"
SIM_NAME="iPhone 17 Pro"
E2E_TMPDIR="${TMPDIR:-/tmp}/claudespy-e2e"
mkdir -p "$E2E_TMPDIR"
SCREENSHOTS_DIR="$E2E_TMPDIR/e2e-screenshots"
BASELINES_DIR="$PROJECT_ROOT/E2ETests"
TMUX_SOCKET="$E2E_TMPDIR/claudespy-e2e.sock"
SKIP_BUILD=false
INTERACTIVE=false
LIST_SCENARIOS=false
NO_COMPARE=false
SCENARIO=""
JSON_OUTPUT=""

# =====================================================
# PARSE ARGUMENTS
# =====================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --sim-name)
            SIM_NAME="$2"
            shift 2
            ;;
        --screenshots)
            SCREENSHOTS_DIR="$2"
            shift 2
            ;;
        --tmux-socket)
            TMUX_SOCKET="$2"
            shift 2
            ;;
        --list-scenarios)
            LIST_SCENARIOS=true
            shift
            ;;
        --scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --no-compare)
            NO_COMPARE=true
            shift
            ;;
        --json-output)
            JSON_OUTPUT="$2"
            shift 2
            ;;
        --dashboard-url)
            DASHBOARD_URL="$2"
            shift 2
            ;;
        --dashboard-pr-number)
            DASHBOARD_PR_NUMBER="$2"
            shift 2
            ;;
        --dashboard-pr-title)
            DASHBOARD_PR_TITLE="$2"
            shift 2
            ;;
        --interactive|-i)
            INTERACTIVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-build     Skip building, use previously built artifacts"
            echo "  --sim-name NAME  iOS Simulator name (default: $SIM_NAME)"
            echo "  --screenshots DIR Screenshot output dir (default: $SCREENSHOTS_DIR)"
            echo "  --tmux-socket PATH Tmux socket path for isolation (default: $TMUX_SOCKET)"
            echo "  --scenario NAME  Run specific scenario by name"
            echo "  --list-scenarios   List all available scenarios and exit"
            echo "  --no-compare       Skip all screenshot comparisons (still takes screenshots)"
            echo "  --json-output FILE Write detailed JSON results to a file"
            echo "  --interactive, -i  Start all apps, wait for Enter, then shut down"
            echo "  -h, --help       Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =====================================================
# CLEAN STALE RESULTS
# =====================================================
# Remove previous JSON output to prevent stale data from being picked up
# if this run fails before the coordinator writes new results.
if [ -n "$JSON_OUTPUT" ]; then
    rm -f "$JSON_OUTPUT"
fi

# =====================================================
# HELPERS
# =====================================================

# Terminal colors (disabled when NO_COLOR is set or stdout is not a tty)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    _BOLD=$'\033[1m'
    _DIM=$'\033[2m'
    _RED=$'\033[31m'
    _GREEN=$'\033[32m'
    _YELLOW=$'\033[33m'
    _CYAN=$'\033[36m'
    _RESET=$'\033[0m'
else
    _BOLD="" _DIM="" _RED="" _GREEN="" _YELLOW="" _CYAN="" _RESET=""
fi

step() {
    echo ""
    echo "${_CYAN}${_BOLD}>>> $1${_RESET}"
}

ok()   { echo "  ${_GREEN}OK${_RESET}  $1"; }
fail() { echo "  ${_RED}FAIL${_RESET}  $1"; }
warn() { echo "  ${_YELLOW}WARN${_RESET}  $1"; }

# XCUITest writes screenshot/video attachments into the simulator's
# InternalDaemon Attachments folders. They are never reaped automatically and
# can grow to many GB across repeated runs. Clear them at the end of every run.
cleanup_simulator_attachments() {
    [ -n "$SIM_UDID" ] || return 0
    local sim_root="$HOME/Library/Developer/CoreSimulator/Devices/$SIM_UDID/data/Containers/Data/InternalDaemon"
    [ -d "$sim_root" ] || return 0
    find "$sim_root" -mindepth 2 -maxdepth 2 -type d -name Attachments -print0 \
        | xargs -0 -I{} find {} -mindepth 1 -delete 2>/dev/null || true
}

cleanup() {
    kill "$CAFFEINATE_PID" 2>/dev/null || true
    cleanup_simulator_attachments
}

# CI machines occasionally show system auth or notification dialogs
# (SecurityAgent admin prompts, software-update nags, "App from the internet"
# warnings) that float above the test apps and block clicks. Dismiss known
# offenders before launching the test so they don't break scenarios. Only
# touches known system processes — never user-facing apps.
dismiss_system_dialogs() {
    # Write the AppleScript to a temp file rather than inlining it as a heredoc
    # inside $(...). macOS ships bash 3.2, whose parser breaks on `$(... <<EOF ... )`
    # when the heredoc body contains `)` — and AppleScript is full of them.
    # The whole script failed to parse, so e2e runs aborted before producing any
    # JSON output and the report falsely labelled them as build failures.
    local script_file
    script_file=$(mktemp -t dismiss-dialogs).scpt
    cat > "$script_file" <<'APPLESCRIPT'
on dismissProcessDialogs(procName)
    set dismissed to {}
    tell application "System Events"
        if not (exists process procName) then return dismissed
        tell process procName
            repeat with w in windows
                try
                    set winName to name of w
                on error
                    set winName to "<untitled>"
                end try
                set clicked to false
                repeat with btnLabel in {"Cancel", "Don't Allow", "Not Now", "Later", "Close"}
                    if not clicked then
                        try
                            if exists button btnLabel of w then
                                click button btnLabel of w
                                set end of dismissed to (procName & ": " & winName & " [" & btnLabel & "]")
                                set clicked to true
                            end if
                        end try
                    end if
                end repeat
            end repeat
        end tell
    end tell
    return dismissed
end dismissProcessDialogs

set allDismissed to {}
repeat with procName in {"SecurityAgent", "UserNotificationCenter", "CoreServicesUIAgent", "loginwindow", "Software Update", "ScreenSaverEngine"}
    try
        set allDismissed to allDismissed & dismissProcessDialogs(procName)
    end try
end repeat

set AppleScript's text item delimiters to linefeed
return allDismissed as text
APPLESCRIPT
    local result
    result=$(osascript "$script_file" 2>/dev/null || true)
    rm -f "$script_file"
    if [ -n "$result" ]; then
        warn "Dismissed blocking system dialog(s):"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "        - $line"
        done <<< "$result"
    else
        ok "No blocking system dialogs"
    fi
}

# Find a booted or available simulator UDID by name
find_simulator_udid() {
    xcrun simctl list devices available -j \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d['name'] == '$SIM_NAME':
            print(d['udid'])
            sys.exit(0)
print('', end='')
sys.exit(1)
"
}

# =====================================================
# PERMISSION CHECKS (macOS)
# =====================================================

# GUI Session: needed for screencapture and window management.
# When logged in as a different user on the CI machine, the WindowServer
# is inaccessible and all screenshot/UI automation silently fails.
check_gui_session() {
    # /dev/console is owned by the user with the active GUI session.
    # When fast-user-switched away, it belongs to the other user.
    local console_user
    console_user=$(stat -f%Su /dev/console 2>/dev/null)
    [ "$console_user" = "$(whoami)" ]
}

# Accessibility: needed for AppleScript UI automation of the macOS app.
# The test must actually send a keystroke — reading process names succeeds
# with a weaker grant that doesn't cover keystroke injection (error 1002).
check_accessibility() {
    # Send a harmless no-op keystroke (empty string) to the frontmost app.
    # This exercises the same code path as the E2E keystroke commands and
    # will fail with error 1002 if the terminal isn't fully authorised.
    if osascript -e 'tell application "System Events" to keystroke ""' 2>/dev/null; then
        return 0
    fi
    return 1
}

# Screen Recording: needed for screencapture of macOS app windows
check_screen_recording() {
    local test_file
    test_file="$(mktemp "${TMPDIR:-/tmp}/e2e-screen-test.XXXXXX").png"
    # Capture a tiny region — if permission is denied the file will be missing or trivially small
    screencapture -x -R0,0,1,1 "$test_file" 2>/dev/null
    local size=0
    if [ -f "$test_file" ]; then
        size=$(stat -f%z "$test_file" 2>/dev/null || echo 0)
        rm -f "$test_file"
    fi
    # A valid 1x1 PNG is >100 bytes; a blank/failed capture is much smaller or absent
    [ "$size" -gt 100 ]
}

# Simulator accessibility: needed for XCUITest runner (loadAccessibility hangs without these)
ensure_simulator_accessibility() {
    local udid="$1"

    # simctl spawn requires a booted device — boot if not already running
    local state
    state=$(xcrun simctl list devices -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d['udid'] == '$udid':
            print(d['state'])
            sys.exit(0)
print('Unknown')
")
    if [ "$state" != "Booted" ]; then
        echo "  Booting simulator ($state)..."
        xcrun simctl boot "$udid" 2>/dev/null || true
        open -a Simulator
        sleep 3
    fi

    local needs_reboot=false
    for key in AccessibilityEnabled ApplicationAccessibilityEnabled AutomationEnabled; do
        local val
        val=$(xcrun simctl spawn "$udid" defaults read com.apple.Accessibility "$key" 2>/dev/null || echo "0")
        if [ "$val" != "1" ]; then
            xcrun simctl spawn "$udid" defaults write com.apple.Accessibility "$key" -bool true
            needs_reboot=true
        fi
    done
    if [ "$needs_reboot" = true ]; then
        echo "  Enabled simulator accessibility settings — rebooting simulator..."
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        sleep 1
        xcrun simctl boot "$udid"
        open -a Simulator
        sleep 3
        echo "  Simulator rebooted."
    fi
}

if [ "$LIST_SCENARIOS" != true ]; then
    # Prevent screensaver and sleep for the entire run (build + tests).
    # -d prevents display sleep, -i prevents idle sleep, -s prevents system sleep,
    # -u asserts "user is active" which also blocks the screen saver (requires -t).
    # 86400s (24h) is far more than any real test run; the EXIT trap kills it sooner.
    # disown drops it from bash's job table so the EXIT trap's kill doesn't
    # print "Terminated: 15".
    caffeinate -disu -t 86400 &
    CAFFEINATE_PID=$!
    disown "$CAFFEINATE_PID" 2>/dev/null || true
    trap cleanup EXIT

    step "Checking GUI session"

    if check_gui_session; then
        ok "GUI session active (current user owns the console)"
    else
        fail "No GUI session available."
        echo "  The current user is not logged into the macOS console session."
        echo "  Screenshots and UI automation require an active desktop."
        echo "  Switch to the CI user's desktop session and try again."
        exit 1
    fi

    step "Checking required permissions"

    missing=false

    if check_accessibility; then
        ok "Accessibility"
    else
        fail "Accessibility"
        missing=true
    fi

    if check_screen_recording; then
        ok "Screen Recording"
    else
        fail "Screen Recording"
        missing=true
    fi

    if [ "$missing" = true ]; then
        echo ""
        warn "The e2e tests require macOS permissions that haven't been granted yet."
        echo "  Your terminal app needs both Accessibility and Screen & System Audio Recording."
        echo ""
        echo "  Opening System Settings — please grant the missing permissions."
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        echo ""
        read -r -p "  Press Enter after granting permissions to re-check..."

        # Re-check
        still_missing=false

        if check_accessibility; then
            ok "Accessibility"
        else
            fail "Accessibility — still not granted"
            still_missing=true
        fi

        if check_screen_recording; then
            ok "Screen Recording"
        else
            fail "Screen Recording — still not granted"
            echo "       (Grant in: System Settings > Privacy & Security > Screen & System Audio Recording)"
            still_missing=true
        fi

        if [ "$still_missing" = true ]; then
            echo ""
            fail "Required permissions not granted. Cannot run e2e tests."
            exit 1
        fi
        echo ""
        ok "All permissions granted."
    fi
fi

# =====================================================
# DERIVED PATHS
# =====================================================
PRODUCTS_DEBUG="$DERIVED_DATA/Build/Products/Debug"
PRODUCTS_SIM="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
MACOS_APP="$PRODUCTS_DEBUG/Gallager.app"
IOS_APP="$PRODUCTS_SIM/Gallager.app"
E2E_BIN="$PRODUCTS_DEBUG/ClaudeSpyE2E"
E2E_HOST_APP="$PRODUCTS_SIM/ClaudeSpyE2EHost.app"

# Assert that an xcodebuild step produced its expected artifact. xcsift
# reports "status: success" whenever no compile errors were parsed, even
# when no executable was emitted — so a missing binary slips through to
# the run step otherwise.
verify_artifact() {
    if [ ! -e "$1" ]; then
        fail "Build reported success but expected artifact is missing: $1"
        exit 1
    fi
}

XCODEBUILD_FLAGS=(
    -workspace "$WORKSPACE"
    -skipMacroValidation
    -skipPackagePluginValidation
)

if [ -z "$SANDBOX_DERIVED_DATA" ]; then
    XCODEBUILD_FLAGS+=(-derivedDataPath "$DERIVED_DATA")
fi

# =====================================================
# LIST SCENARIOS (no build needed)
# =====================================================
if [ "$LIST_SCENARIOS" = true ]; then
    if [ ! -e "$E2E_BIN" ]; then
        echo "ERROR: E2E binary not found at $E2E_BIN"
        echo "Run without --skip-build first."
        exit 1
    fi
    "$E2E_BIN" --list-scenarios
    exit 0
fi

# =====================================================
# BUILD PHASE
# =====================================================
if [ "$SKIP_BUILD" = true ]; then
    step "Skipping build (--skip-build)"

    # Verify artifacts exist
    missing=false
    for artifact in "$MACOS_APP" "$IOS_APP" "$E2E_BIN"; do
        if [ ! -e "$artifact" ]; then
            fail "Missing artifact: $artifact"
            missing=true
        fi
    done
    if [ "$missing" = true ]; then
        fail "Run without --skip-build first."
        exit 1
    fi
    ok "All artifacts found."

    # Find simulator UDID for accessibility check
    SIM_UDID=$(find_simulator_udid)
else
    # Find simulator for iOS build destination
    SIM_UDID=$(find_simulator_udid)
    if [ -z "$SIM_UDID" ]; then
        fail "No simulator found with name '$SIM_NAME'"
        echo "  Available simulators:"
        xcrun simctl list devices available | grep iPhone | head -10
        exit 1
    fi
    ok "Simulator: ${_BOLD}$SIM_NAME${_RESET} ($SIM_UDID)"

    # Build macOS targets contiguously so the Sparkle precompiled module stays
    # consistent between consumers. Interleaving an iOS build between the macOS
    # app and the E2E coordinator caused intermittent "header has been modified"
    # PCM-cache failures because the iOS build path regenerates Sparkle's
    # umbrella header.
    step "Building macOS app (ClaudeSpyServer)"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpyServer \
        -destination 'platform=macOS' \
        build 2>&1 | xcsift --format toon --executable
    verify_artifact "$MACOS_APP"

    step "Building E2E coordinator"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpyE2E \
        -destination 'platform=macOS' \
        build 2>&1 | xcsift --format toon --executable
    verify_artifact "$E2E_BIN"

    step "Building iOS app (ClaudeSpy)"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpy \
        -destination "id=$SIM_UDID" \
        build 2>&1 | xcsift --format toon --executable
    verify_artifact "$IOS_APP"

    step "Building E2E XCUITest runner (ClaudeSpyE2EHost)"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpyE2EHost \
        -destination "id=$SIM_UDID" \
        build-for-testing 2>&1 | xcsift --format toon --executable
    verify_artifact "$E2E_HOST_APP"
fi

# =====================================================
# SIMULATOR ACCESSIBILITY
# =====================================================
# XCUITest runner hangs at loadAccessibility if these are disabled.
# This can happen on fresh simulators or after a device reset.
if [ -n "$SIM_UDID" ]; then
    step "Checking simulator accessibility"
    ensure_simulator_accessibility "$SIM_UDID"
    ok "Simulator accessibility enabled"
fi

# =====================================================
# CLEANUP STALE TEST PROCESSES
# =====================================================
# Kill any leftover Gallager processes from previous E2E runs.
# Only kills E2E instances (launched with --e2e-test flag), not the user's
# regular app. A stale test process holding port 18081
# causes all macSetSidebarWidth calls to fail.
stale_pids=$(ps -eo pid,command | grep "[G]allager" | grep "\-\-e2e-test" | awk '{print $1}' || true)
if [ -n "$stale_pids" ]; then
    step "Killing stale test Gallager processes"
    for pid in $stale_pids; do
        kill "$pid" 2>/dev/null || true
    done
    sleep 1
    # Force-kill any that didn't terminate gracefully
    for pid in $stale_pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
    ok "Stale processes cleaned up"
fi

# =====================================================
# DISMISS BLOCKING SYSTEM DIALOGS
# =====================================================
step "Dismissing blocking system dialogs"
dismiss_system_dialogs

# =====================================================
# RUN E2E TEST
# =====================================================
if [ "$INTERACTIVE" = true ]; then
    step "Starting interactive mode"
else
    step "Running E2E test"
fi

echo "${_DIM}  macOS app:   $MACOS_APP"
echo "  iOS app:     $IOS_APP"
echo "  Simulator:   $SIM_NAME"
echo "  Tmux socket: $TMUX_SOCKET"
echo "  Screenshots: $SCREENSHOTS_DIR"
echo "  Baselines:   $BASELINES_DIR${_RESET}"
echo ""

E2E_ARGS=(
    --ios-app-path "$IOS_APP"
    --macos-app-path "$MACOS_APP"
    --sim-name "$SIM_NAME"
    --screenshots-dir "$SCREENSHOTS_DIR"
    --baselines-dir "$BASELINES_DIR"
    --tmux-socket "$TMUX_SOCKET"
    --e2e-runner-path "$DERIVED_DATA"
)

if [ "$INTERACTIVE" = true ]; then
    E2E_ARGS+=(--interactive)
fi

if [ -n "$SCENARIO" ]; then
    E2E_ARGS+=(--scenario "$SCENARIO")
fi

if [ "$NO_COMPARE" = true ]; then
    E2E_ARGS+=(--no-compare)
fi

if [ -n "$JSON_OUTPUT" ]; then
    E2E_ARGS+=(--json-output "$JSON_OUTPUT")
fi

if [ -n "$DASHBOARD_URL" ]; then
    E2E_ARGS+=(--dashboard-url "$DASHBOARD_URL")
fi

if [ -n "$DASHBOARD_PR_NUMBER" ]; then
    E2E_ARGS+=(--dashboard-pr-number "$DASHBOARD_PR_NUMBER")
fi

if [ -n "$DASHBOARD_PR_TITLE" ]; then
    E2E_ARGS+=(--dashboard-pr-title "$DASHBOARD_PR_TITLE")
fi

DYLD_FRAMEWORK_PATH="$PRODUCTS_DEBUG" "$E2E_BIN" "${E2E_ARGS[@]}"
