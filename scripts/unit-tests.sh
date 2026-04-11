#!/bin/bash

# Unit Test Script for ClaudeSpy
# Runs all unit tests in the ClaudeSpyPackage via swift test

set -eo pipefail

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="$PROJECT_ROOT/ClaudeSpyPackage"

# =====================================================
# PARSE ARGUMENTS
# =====================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [-- SWIFT_TEST_ARGS...]"
            echo ""
            echo "Runs all unit tests in ClaudeSpyPackage using swift test."
            echo ""
            echo "Any arguments after -- are passed through to swift test."
            echo ""
            echo "Examples:"
            echo "  $0                              Run all tests"
            echo "  $0 -- --filter Networking        Run only Networking tests"
            echo "  $0 -- --filter TerminalCopyTests  Run a specific test suite"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1 (use -- to pass args to swift test)"
            exit 1
            ;;
    esac
done

# =====================================================
# HELPERS
# =====================================================

# Terminal colors (disabled when NO_COLOR is set or stdout is not a tty)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    _BOLD=$'\033[1m'
    _RED=$'\033[31m'
    _GREEN=$'\033[32m'
    _CYAN=$'\033[36m'
    _RESET=$'\033[0m'
else
    _BOLD="" _RED="" _GREEN="" _CYAN="" _RESET=""
fi

# =====================================================
# RUN TESTS
# =====================================================
echo ""
echo "${_CYAN}${_BOLD}>>> Running unit tests${_RESET}"
echo ""

cd "$PACKAGE_DIR"
# Override the deployment target used by swiftc when building the SPM
# test bundle. Without this, SPM links the test bundle with macOS 11.0 as its
# minimum deployment target (the swiftc default for the host), which produces
# linker warnings against swift-testing and XCTestSwiftSupport built for 14.0+.
HOST_ARCH="$(uname -m)"
swift test --parallel \
    -Xswiftc -target -Xswiftc "${HOST_ARCH}-apple-macos15.0" \
    "$@"
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "${_GREEN}${_BOLD}All unit tests passed.${_RESET}"
else
    echo "${_RED}${_BOLD}Unit tests failed (exit code: $EXIT_CODE).${_RESET}"
fi

exit $EXIT_CODE
