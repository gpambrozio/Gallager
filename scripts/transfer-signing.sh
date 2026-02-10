#!/bin/bash

# Transfer Signing Credentials for ClaudeSpy
# Exports/imports certificates and provisioning profiles between machines.
#
# Usage:
#   ./scripts/transfer-signing.sh export    # on the source Mac
#   ./scripts/transfer-signing.sh import    # on the destination Mac

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUNDLE_ID_PREFIX="br.eng.gustavo.claudespy"
TEAM_ID="XG2WG7U93U"
ARCHIVE_NAME="claudespy-signing.tar.gz"
ARCHIVE_PATH="$PROJECT_ROOT/$ARCHIVE_NAME"

# =====================================================
# EXPORT
# =====================================================
do_export() {
    echo "=== Exporting signing credentials ==="

    local work_dir
    work_dir=$(mktemp -d)

    # --- Certificates ---
    echo ""
    echo "Current codesigning identities:"
    security find-identity -v -p codesigning
    echo ""

    # Find the login keychain path
    local keychain
    keychain=$(security default-keychain -d user | tr -d '"' | xargs)

    echo "Exporting signing identities from: $keychain"
    echo "You may see Keychain Access prompts — click 'Allow' or 'Always Allow'."
    echo ""

    read -rsp "Choose an export password (needed for import): " export_password
    echo ""
    read -rsp "Confirm password: " export_password_confirm
    echo ""

    if [ "$export_password" != "$export_password_confirm" ]; then
        echo "Error: passwords do not match."
        rm -rf "$work_dir"
        exit 1
    fi

    security export \
        -k "$keychain" \
        -t identities \
        -f pkcs12 \
        -P "$export_password" \
        -o "$work_dir/certificates.p12"

    echo "OK Certificates exported"

    # --- Provisioning Profiles ---
    local profiles_dir="$work_dir/profiles"
    mkdir -p "$profiles_dir"

    local profile_count=0
    local profiles_source="$HOME/Library/MobileDevice/Provisioning Profiles"

    if [ ! -d "$profiles_source" ]; then
        echo "Warning: No provisioning profiles directory found at $profiles_source"
    else
        for profile in "$profiles_source"/*.mobileprovision "$profiles_source"/*.provisionprofile; do
            [ -f "$profile" ] || continue

            local decoded
            decoded=$(security cms -D -i "$profile" 2>/dev/null) || continue

            if echo "$decoded" | grep -q "$BUNDLE_ID_PREFIX"; then
                local name app_id
                name=$(echo "$decoded" | plutil -extract Name raw - 2>/dev/null || echo "unknown")
                app_id=$(echo "$decoded" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || \
                         echo "$decoded" | plutil -extract Entitlements.com.apple.application-identifier raw - 2>/dev/null || \
                         echo "unknown")

                cp "$profile" "$profiles_dir/"
                echo "  Found: $name ($app_id)"
                profile_count=$((profile_count + 1))
            fi
        done
    fi

    echo "OK $profile_count provisioning profile(s) found"

    # --- Package ---
    tar -czf "$ARCHIVE_PATH" -C "$work_dir" .
    rm -rf "$work_dir"

    echo ""
    echo "=== Export complete ==="
    echo "Archive: $ARCHIVE_PATH"
    echo ""
    echo "Transfer this file to the other machine, place it in the project root,"
    echo "and run:  ./scripts/transfer-signing.sh import"
}

# =====================================================
# IMPORT
# =====================================================
do_import() {
    if [ ! -f "$ARCHIVE_PATH" ]; then
        echo "Error: $ARCHIVE_PATH not found."
        echo "Place the archive in the project root first."
        exit 1
    fi

    echo "=== Importing signing credentials ==="

    local work_dir
    work_dir=$(mktemp -d)
    tar -xzf "$ARCHIVE_PATH" -C "$work_dir"

    # --- Certificates ---
    echo ""
    read -rsp "Import password (same as export): " import_password
    echo ""

    local keychain
    keychain=$(security default-keychain -d user | tr -d '"' | xargs)

    security import "$work_dir/certificates.p12" \
        -k "$keychain" \
        -P "$import_password" \
        -T /usr/bin/codesign \
        -T /usr/bin/security

    echo "OK Certificates imported"

    # --- Provisioning Profiles ---
    local dest_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$dest_dir"

    local profile_count=0
    for profile in "$work_dir"/profiles/*.mobileprovision "$work_dir"/profiles/*.provisionprofile; do
        [ -f "$profile" ] || continue
        cp "$profile" "$dest_dir/"
        echo "  Installed: $(basename "$profile")"
        profile_count=$((profile_count + 1))
    done

    echo "OK $profile_count provisioning profile(s) installed"

    rm -rf "$work_dir"

    # --- Verify ---
    echo ""
    echo "Imported codesigning identities:"
    security find-identity -v -p codesigning
    echo ""

    echo "=== Import complete ==="
    echo ""
    echo "Next steps in Xcode (for each target):"
    echo "  1. Uncheck 'Automatically manage signing'"
    echo "  2. Select team: $TEAM_ID"
    echo "  3. Choose the imported provisioning profile"
}

# =====================================================
# MAIN
# =====================================================
case "${1:-}" in
    export) do_export ;;
    import) do_import ;;
    *)
        echo "Usage: $0 <export|import>"
        echo ""
        echo "  export  Export certificates + provisioning profiles from this Mac"
        echo "  import  Import certificates + provisioning profiles to this Mac"
        exit 1
        ;;
esac
