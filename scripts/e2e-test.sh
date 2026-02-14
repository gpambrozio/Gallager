#!/bin/bash

# E2E Test Script for ClaudeSpy
# Builds all targets and runs the E2E test coordinator

set -e

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$PROJECT_ROOT/ClaudeSpy.xcworkspace"
DERIVED_DATA="$PROJECT_ROOT/build/e2e-derived-data"
SIM_NAME="iPhone 17 Pro"
SCREENSHOTS_DIR="/tmp/e2e-screenshots"
BASELINES_DIR="$PROJECT_ROOT/E2ETests"
TMUX_SOCKET="/tmp/claudespy-e2e.sock"
SKIP_BUILD=false
INTERACTIVE=false
LIST_SCENARIOS=false
SCENARIO=""

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
# DERIVED PATHS
# =====================================================
PRODUCTS_DEBUG="$DERIVED_DATA/Build/Products/Debug"
PRODUCTS_SIM="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
MACOS_APP="$PRODUCTS_DEBUG/Gallager.app"
IOS_APP="$PRODUCTS_SIM/Gallager.app"
E2E_BIN="$PRODUCTS_DEBUG/ClaudeSpyE2E"

XCODEBUILD_FLAGS=(
    -workspace "$WORKSPACE"
    -derivedDataPath "$DERIVED_DATA"
    -skipMacroValidation
    -skipPackagePluginValidation
)

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

"$E2E_BIN" "${E2E_ARGS[@]}"
