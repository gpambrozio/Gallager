#!/bin/bash

# SwiftLint build phase script
# Runs SwiftLint in strict mode on the ClaudeSpyPackage

if which swiftlint >/dev/null; then
    cd "${SRCROOT}/ClaudeSpyPackage" || exit 1
    swiftlint lint --strict
else
    echo "warning: SwiftLint not installed, install it with 'brew install swiftlint'"
    exit 0
fi
