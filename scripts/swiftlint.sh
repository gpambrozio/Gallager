#!/bin/bash

# SwiftLint build phase script
# Runs SwiftLint in strict mode on the ClaudeSpyPackage

# Add Homebrew paths since Xcode build phases don't inherit shell configuration
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if which swiftlint >/dev/null; then
    cd "${SRCROOT}/ClaudeSpyPackage" || exit 1
    swiftlint lint --strict
else
    echo "warning: SwiftLint not installed, install it with 'brew install swiftlint'"
    exit 0
fi
