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

    # --- Certificates (filtered to TEAM_ID only) ---
    echo ""
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

    # Find the login keychain path
    local keychain
    keychain=$(security default-keychain -d user | tr -d '"' | xargs)

    # Export ALL identities to a temp .p12, then filter via a temporary keychain
    local temp_p12="$work_dir/all-identities.p12"
    local temp_keychain="$work_dir/temp-filter.keychain-db"
    local temp_kc_password="temp-export-pw"

    security export \
        -k "$keychain" \
        -t identities \
        -f pkcs12 \
        -P "$export_password" \
        -o "$temp_p12"

    # Create temporary keychain and import everything into it
    security create-keychain -p "$temp_kc_password" "$temp_keychain"
    security unlock-keychain -p "$temp_kc_password" "$temp_keychain"
    security import "$temp_p12" \
        -k "$temp_keychain" \
        -P "$export_password" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
    rm -f "$temp_p12"

    # Build a list of certificate SHA-1 hashes that belong to our team.
    # The team ID appears in the certificate subject's OU field. For "Apple
    # Development" certs the alias shows the member ID, not the team ID, so
    # we check the "subj" blob which contains the raw DER subject — the team
    # ID string always appears in the decoded text portion.
    local -a team_cert_hashes=()
    local current_hash=""

    while IFS= read -r line; do
        if [[ "$line" == *"SHA-1 hash:"* ]]; then
            current_hash=$(echo "$line" | awk '{print $3}')
        elif [[ "$line" == *"\"subj\""* ]] && [[ "$line" == *"$TEAM_ID"* ]] && [ -n "$current_hash" ]; then
            team_cert_hashes+=("$current_hash")
            current_hash=""
        fi
    done < <(security find-certificate -a -Z "$temp_keychain")

    if [ ${#team_cert_hashes[@]} -eq 0 ]; then
        echo "Error: no certificates found for team $TEAM_ID."
        security delete-keychain "$temp_keychain" 2>/dev/null || true
        rm -rf "$work_dir"
        exit 1
    fi

    echo "Found ${#team_cert_hashes[@]} certificate(s) for team $TEAM_ID:"

    # Delete certificates that do NOT belong to our team
    while IFS= read -r cert_hash; do
        local keep=false
        for team_hash in "${team_cert_hashes[@]}"; do
            if [ "$cert_hash" = "$team_hash" ]; then
                keep=true
                break
            fi
        done
        if [ "$keep" = false ]; then
            security delete-certificate -Z "$cert_hash" "$temp_keychain" 2>/dev/null || true
        fi
    done < <(security find-certificate -a -Z "$temp_keychain" \
        | grep "SHA-1 hash:" | awk '{print $3}')

    # Show what we're exporting
    security find-identity -v -p codesigning "$temp_keychain" 2>/dev/null || true

    # Export only the remaining (team-filtered) identities
    security export \
        -k "$temp_keychain" \
        -t identities \
        -f pkcs12 \
        -P "$export_password" \
        -o "$work_dir/certificates.p12"

    # Cleanup temp keychain
    security delete-keychain "$temp_keychain" 2>/dev/null || true

    echo "OK Certificates exported (team $TEAM_ID only)"

    # --- Provisioning Profiles ---
    local profiles_dir="$work_dir/profiles"
    mkdir -p "$profiles_dir"

    local profile_count=0

    # Xcode stores auto-managed profiles in two locations
    local profile_sources=(
        "$HOME/Library/MobileDevice/Provisioning Profiles"
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    )

    for profiles_source in "${profile_sources[@]}"; do
        [ -d "$profiles_source" ] || continue

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

                # Avoid duplicates if same profile exists in both locations
                local basename
                basename=$(basename "$profile")
                if [ ! -f "$profiles_dir/$basename" ]; then
                    cp "$profile" "$profiles_dir/"
                    echo "  Found: $name ($app_id)"
                    profile_count=$((profile_count + 1))
                fi
            fi
        done
    done

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
    # Install to both locations so Xcode can find them regardless of version
    local dest_dirs=(
        "$HOME/Library/MobileDevice/Provisioning Profiles"
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    )

    local profile_count=0
    for profile in "$work_dir"/profiles/*.mobileprovision "$work_dir"/profiles/*.provisionprofile; do
        [ -f "$profile" ] || continue
        for dest_dir in "${dest_dirs[@]}"; do
            mkdir -p "$dest_dir"
            cp "$profile" "$dest_dir/"
        done
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
