#!/bin/bash

# E2E Test Script for ClaudeSpy
# Builds all targets and runs the E2E test coordinator

set -eo pipefail

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$PROJECT_ROOT/ClaudeSpy.xcworkspace"
DERIVED_DATA="${SANDBOX_DERIVED_DATA:-$PROJECT_ROOT/build/e2e-derived-data}"
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
step() {
    echo ""
    echo "======================================"
    echo "  $1"
    echo "======================================"
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

# Accessibility: needed for AppleScript UI automation of the macOS app
check_accessibility() {
    if osascript -e 'tell application "System Events" to get name of first process' &>/dev/null; then
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
    step "Checking required permissions"

    missing=false

    if check_accessibility; then
        echo "  [OK] Accessibility"
    else
        echo "  [MISSING] Accessibility"
        missing=true
    fi

    if check_screen_recording; then
        echo "  [OK] Screen Recording"
    else
        echo "  [MISSING] Screen Recording"
        missing=true
    fi

    if [ "$missing" = true ]; then
        echo ""
        echo "The e2e tests require macOS permissions that haven't been granted yet."
        echo "Your terminal app needs both Accessibility and Screen & System Audio Recording."
        echo ""
        echo "Opening System Settings — please grant the missing permissions."
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        echo ""
        read -r -p "Press Enter after granting permissions to re-check..."

        # Re-check
        still_missing=false

        if check_accessibility; then
            echo "  [OK] Accessibility"
        else
            echo "  [MISSING] Accessibility — still not granted"
            still_missing=true
        fi

        if check_screen_recording; then
            echo "  [OK] Screen Recording"
        else
            echo "  [MISSING] Screen Recording — still not granted"
            echo "         (Grant in: System Settings > Privacy & Security > Screen & System Audio Recording)"
            still_missing=true
        fi

        if [ "$still_missing" = true ]; then
            echo ""
            echo "ERROR: Required permissions not granted. Cannot run e2e tests."
            exit 1
        fi
        echo ""
        echo "All permissions granted."
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
            echo "ERROR: Missing artifact: $artifact"
            missing=true
        fi
    done
    if [ "$missing" = true ]; then
        echo "Run without --skip-build first."
        exit 1
    fi
    echo "All artifacts found."

    # Find simulator UDID for accessibility check
    SIM_UDID=$(find_simulator_udid)
else
    # Find simulator for iOS build destination
    SIM_UDID=$(find_simulator_udid)
    if [ -z "$SIM_UDID" ]; then
        echo "ERROR: No simulator found with name '$SIM_NAME'"
        echo "Available simulators:"
        xcrun simctl list devices available | grep iPhone | head -10
        exit 1
    fi
    echo "Using simulator: $SIM_NAME ($SIM_UDID)"

    step "Building macOS app (ClaudeSpyServer)"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpyServer \
        -destination 'platform=macOS' \
        build 2>&1 | xcsift --format toon --warnings --executable

    step "Building iOS app (ClaudeSpy)"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpy \
        -destination "id=$SIM_UDID" \
        build 2>&1 | xcsift --format toon --warnings --executable

    step "Building E2E XCUITest runner (ClaudeSpyE2EHost)"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpyE2EHost \
        -destination "id=$SIM_UDID" \
        build-for-testing 2>&1 | xcsift --format toon --warnings --executable

    step "Building E2E coordinator"
    xcodebuild "${XCODEBUILD_FLAGS[@]}" \
        -scheme ClaudeSpyE2E \
        -destination 'platform=macOS' \
        build 2>&1 | xcsift --format toon --warnings --executable
fi

# =====================================================
# SIMULATOR ACCESSIBILITY
# =====================================================
# XCUITest runner hangs at loadAccessibility if these are disabled.
# This can happen on fresh simulators or after a device reset.
if [ -n "$SIM_UDID" ]; then
    step "Checking simulator accessibility"
    ensure_simulator_accessibility "$SIM_UDID"
    echo "  [OK] Simulator accessibility enabled"
fi

# =====================================================
# RUN E2E TEST
# =====================================================
if [ "$INTERACTIVE" = true ]; then
    step "Starting interactive mode"
else
    step "Running E2E test"
fi

echo "macOS app:   $MACOS_APP"
echo "iOS app:     $IOS_APP"
echo "Simulator:   $SIM_NAME"
echo "Tmux socket: $TMUX_SOCKET"
echo "Screenshots: $SCREENSHOTS_DIR"
echo "Baselines:   $BASELINES_DIR"
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

"$E2E_BIN" "${E2E_ARGS[@]}"
