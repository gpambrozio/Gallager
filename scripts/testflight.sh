#!/bin/bash

# TestFlight Release Script for ClaudeSpy iOS App
# Builds, archives, and uploads to TestFlight
#
# Prerequisites:
#   1. App Store Connect API Key with "App Manager" role
#   2. Key file at: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   3. Set environment variables or pass as arguments:
#      - APP_STORE_CONNECT_API_KEY_ID (or --api-key)
#      - APP_STORE_CONNECT_ISSUER_ID (or --api-issuer)

set -e

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$PROJECT_ROOT/ClaudeSpy.xcworkspace"
SCHEME="ClaudeSpy"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
EXPORT_OPTIONS="$SCRIPT_DIR/export-options-ios.plist"
BUILD_DIR="$PROJECT_ROOT/build-ios"
ARCHIVE_PATH="$BUILD_DIR/Gallager.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="Gallager"
TEAM_ID="XG2WG7U93U"
BUNDLE_ID="br.eng.gustavo.claudespy"
ASC_API_BASE="https://api.appstoreconnect.apple.com/v1"

# =====================================================
# Colors for output
# =====================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =====================================================
# Parse arguments
# =====================================================
SKIP_UPLOAD=false
EXPORT_ONLY=false
AUTO_YES=false
SET_CHANGELOG=false
API_KEY=""
API_ISSUER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-upload)
            SKIP_UPLOAD=true
            shift
            ;;
        --export-only)
            EXPORT_ONLY=true
            shift
            ;;
        --set-changelog)
            SET_CHANGELOG=true
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --api-key)
            API_KEY="$2"
            shift 2
            ;;
        --api-issuer)
            API_ISSUER="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-upload       Build, archive, and export IPA but don't upload"
            echo "  --export-only       Same as --skip-upload (alias)"
            echo "  --set-changelog     Set TestFlight 'What to Test' from git commits (run after build processes)"
            echo "  --yes, -y           Skip confirmation prompts"
            echo "  --api-key KEY       App Store Connect API Key ID"
            echo "  --api-issuer ID     App Store Connect API Issuer ID"
            echo "  --help              Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  APP_STORE_CONNECT_API_KEY_ID   API Key ID (alternative to --api-key)"
            echo "  APP_STORE_CONNECT_ISSUER_ID    API Issuer ID (alternative to --api-issuer)"
            echo ""
            echo "Setup instructions:"
            echo "  1. Go to App Store Connect > Users and Access > Integrations"
            echo "  2. Create a new API key with 'App Manager' role"
            echo "  3. Download the .p8 file"
            echo "  4. Save to: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"
            echo "  5. Export the credentials:"
            echo "     export APP_STORE_CONNECT_API_KEY_ID=<your_key_id>"
            echo "     export APP_STORE_CONNECT_ISSUER_ID=<your_issuer_id>"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Treat --export-only same as --skip-upload
if [ "$EXPORT_ONLY" = true ]; then
    SKIP_UPLOAD=true
fi

# Use environment variables as fallback
API_KEY="${API_KEY:-$APP_STORE_CONNECT_API_KEY_ID}"
API_ISSUER="${API_ISSUER:-$APP_STORE_CONNECT_ISSUER_ID}"

# =====================================================
# Helper functions
# =====================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

get_version() {
    grep "^MARKETING_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' '
}

get_build_number() {
    grep "^CURRENT_PROJECT_VERSION" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' '
}

# =====================================================
# App Store Connect API helpers
# =====================================================
base64url_encode() {
    openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

generate_jwt() {
    local key_path="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY}.p8"
    local now
    now=$(date +%s)
    local exp=$((now + 1200))

    local header
    header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$API_KEY" | base64url_encode)
    local payload
    payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' "$API_ISSUER" "$now" "$exp" | base64url_encode)

    # openssl produces DER-encoded ECDSA, but JWT ES256 needs raw R||S (64 bytes)
    local signature
    signature=$(printf '%s.%s' "$header" "$payload" \
        | openssl dgst -sha256 -sign "$key_path" -binary \
        | python3 -c "
import sys
der = sys.stdin.buffer.read()
# Parse DER SEQUENCE -> two INTEGERs (R, S)
pos = 2 + (der[1] & 0x7f if der[1] & 0x80 else 0)
assert der[pos] == 0x02
r_len = der[pos+1]; r = der[pos+2:pos+2+r_len]; pos += 2 + r_len
assert der[pos] == 0x02
s_len = der[pos+1]; s = der[pos+2:pos+2+s_len]
sys.stdout.buffer.write(r[-32:].rjust(32, b'\x00') + s[-32:].rjust(32, b'\x00'))
" \
        | base64url_encode)

    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

asc_get() {
    local token
    token=$(generate_jwt)
    curl -s --globoff -H "Authorization: Bearer $token" -H "Content-Type: application/json" "${ASC_API_BASE}$1"
}

asc_post() {
    local token
    token=$(generate_jwt)
    curl -s --globoff -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$2" "${ASC_API_BASE}$1"
}

asc_patch() {
    local token
    token=$(generate_jwt)
    curl -s --globoff -X PATCH -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$2" "${ASC_API_BASE}$1"
}

generate_changelog() {
    local current_version
    current_version=$(get_version)

    local prev_tag
    prev_tag=$(git -C "$PROJECT_ROOT" tag --sort=-v:refname \
        | grep -Ev "^v?${current_version}$" \
        | head -1)

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

Generate concise, tester-friendly notes for version $(get_version) of Gallager (ClaudeSpy), an iOS app for remotely monitoring Claude Code sessions.

IMPORTANT: This is an independent open source project. It is NOT affiliated with or built by Anthropic.

Here are the commits since the last release:
$commits

Requirements:
- Only include changes relevant to the iOS app or that could indirectly affect it (e.g. shared networking, encryption, server relay changes)
- Skip commits that only affect the macOS app, build scripts, CI, or docs
- Group changes by category (New Features, Improvements, Bug Fixes) if applicable
- Explain what each change means for testers — what to look for, what might break
- Keep it concise but informative — this is TestFlight, not a press release
- Use plain text, no markdown (TestFlight renders plain text only)
- Do NOT wrap output in code fences, backticks, or any formatting wrappers
- Do NOT include ANY preamble, commentary, thinking, or meta-text — start directly with the content
- Do NOT add URLs, links, or 'for more information' sections
- Output ONLY the What to Test content itself
- If no commits are relevant to iOS, output: No iOS-relevant changes in this build."

    local notes
    notes=$(claude -p "$prompt" 2>/dev/null) || {
        log_warning "Claude failed to generate notes, using raw commit list" >&2
        echo "$commits"
        return
    }

    # Strip code fences and any preamble before the actual content
    notes=$(echo "$notes" | sed '/^```/d' | sed '/^Gallager/,$!d')

    echo "$notes"
}

find_app_id() {
    local response
    response=$(asc_get "/apps?filter[bundleId]=${BUNDLE_ID}&fields[apps]=bundleId")
    local app_id
    app_id=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)

    if [ -z "$app_id" ]; then
        log_error "Could not find app with bundle ID: $BUNDLE_ID
API response: $response"
    fi
    echo "$app_id"
}

find_build_id() {
    local app_id="$1"
    local build_number="$2"
    local response
    response=$(asc_get "/builds?filter[app]=${app_id}&filter[version]=${build_number}&fields[builds]=version,processingState")
    local build_id
    build_id=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)
    local state
    state=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['attributes']['processingState'])" 2>/dev/null)

    if [ -z "$build_id" ]; then
        log_error "Could not find build $build_number for app $app_id
The build may not have been uploaded yet, or is still being ingested.
API response: $response"
    fi

    if [ "$state" != "VALID" ]; then
        log_error "Build $build_number is still processing (state: $state).
Wait for processing to complete and try again."
    fi

    echo "$build_id"
}

set_whats_new() {
    local build_id="$1"
    local changelog="$2"

    local escaped_changelog
    escaped_changelog=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" <<< "$changelog")

    # Check for existing localization
    local response
    response=$(asc_get "/builds/${build_id}/betaBuildLocalizations")
    local loc_id
    loc_id=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d.get('data', []):
    if item['attributes'].get('locale') == 'en-US':
        print(item['id'])
        break
" 2>/dev/null)

    if [ -n "$loc_id" ]; then
        log_info "Updating existing en-US localization..."
        asc_patch "/betaBuildLocalizations/${loc_id}" \
            "{\"data\":{\"type\":\"betaBuildLocalizations\",\"id\":\"${loc_id}\",\"attributes\":{\"whatsNew\":${escaped_changelog}}}}" > /dev/null
    else
        log_info "Creating en-US localization..."
        asc_post "/betaBuildLocalizations" \
            "{\"data\":{\"type\":\"betaBuildLocalizations\",\"attributes\":{\"locale\":\"en-US\",\"whatsNew\":${escaped_changelog}},\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"${build_id}\"}}}}}" > /dev/null
    fi

    log_success "What to Test notes updated"
}

# =====================================================
# Check prerequisites
# =====================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v xcrun &> /dev/null; then
        log_error "Xcode command line tools are not installed."
    fi

    if [ "$SKIP_UPLOAD" != true ]; then
        if [ -z "$API_KEY" ] || [ -z "$API_ISSUER" ]; then
            log_error "App Store Connect API credentials required for upload.

Set them via:
  --api-key KEY --api-issuer ISSUER

Or environment variables:
  export APP_STORE_CONNECT_API_KEY_ID=your_key_id
  export APP_STORE_CONNECT_ISSUER_ID=your_issuer_id

To create an API key:
  1. Go to App Store Connect > Users and Access > Integrations > App Store Connect API
  2. Create a new key with 'App Manager' role
  3. Download the .p8 file to ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8

Use --skip-upload to build without uploading."
        fi

        local key_path="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY}.p8"
        if [ ! -f "$key_path" ]; then
            log_error "API key file not found at: $key_path

Download your API key from App Store Connect and save it there."
        fi
    fi

    if [[ -n $(git -C "$PROJECT_ROOT" status --porcelain) ]]; then
        log_warning "Git working directory has uncommitted changes."
        if [ "$AUTO_YES" != true ]; then
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_error "Release cancelled. Please commit or stash changes first."
            fi
        fi
    fi

    log_success "All prerequisites satisfied"
}

# =====================================================
# Build archive
# =====================================================
build_archive() {
    log_info "Building iOS archive..."

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    xcodebuild archive \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=iOS" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        -quiet \
        || log_error "Archive build failed"

    log_success "Archive built successfully"
}

# =====================================================
# Export archive for App Store
# =====================================================
export_archive() {
    log_info "Exporting archive for App Store..."

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates \
        -quiet \
        || log_error "Archive export failed"

    log_success "Archive exported successfully"
}

# =====================================================
# Upload to TestFlight
# =====================================================
upload_to_testflight() {
    if [ "$SKIP_UPLOAD" = true ]; then
        log_warning "Skipping TestFlight upload"
        return
    fi

    log_info "Uploading to TestFlight..."

    local ipa_path
    ipa_path=$(find "$EXPORT_PATH" -name "*.ipa" -print -quit)

    if [ -z "$ipa_path" ]; then
        log_error "No IPA file found in export path"
    fi

    log_info "Uploading: $(basename "$ipa_path")"

    local upload_output
    upload_output=$(xcrun altool --upload-app \
        --type ios \
        --file "$ipa_path" \
        --apiKey "$API_KEY" \
        --apiIssuer "$API_ISSUER" 2>&1)
    local upload_status=$?

    echo "$upload_output"

    if [ $upload_status -ne 0 ] || echo "$upload_output" | grep -q "UPLOAD FAILED"; then
        log_error "TestFlight upload failed"
    fi

    log_success "Upload to TestFlight complete!"
}

# =====================================================
# Main
# =====================================================
main() {
    echo ""
    echo "=========================================="
    echo "  ClaudeSpy iOS TestFlight Release"
    echo "=========================================="
    echo ""

    local version
    version=$(get_version)
    local build_number
    build_number=$(get_build_number)

    # --set-changelog mode: skip build, just update What to Test
    if [ "$SET_CHANGELOG" = true ]; then
        if [ -z "$API_KEY" ] || [ -z "$API_ISSUER" ]; then
            log_error "API credentials required for --set-changelog. See --help."
        fi

        log_info "Version: $version (build $build_number)"

        local changelog
        changelog=$(generate_changelog)
        if [ -z "$changelog" ]; then
            log_error "No commits found for changelog"
        fi

        echo ""
        echo "Changelog:"
        echo "$changelog"
        echo ""

        if [ "$AUTO_YES" != true ]; then
            read -p "Set this as 'What to Test' for build $build_number? (y/N) " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Cancelled"
                exit 0
            fi
        fi

        log_info "Looking up app..."
        local app_id
        app_id=$(find_app_id)
        log_info "App ID: $app_id"

        log_info "Looking up build $build_number..."
        local build_id
        build_id=$(find_build_id "$app_id" "$build_number")
        log_info "Build ID: $build_id"

        set_whats_new "$build_id" "$changelog"

        echo ""
        log_success "What to Test updated for build $build_number"
        echo ""
        exit 0
    fi

    check_prerequisites
    log_info "Version: $version (build $build_number)"

    if [ "$AUTO_YES" != true ]; then
        echo ""
        if [ "$SKIP_UPLOAD" = true ]; then
            read -p "Build version $version for TestFlight (no upload)? (y/N) " -n 1 -r
        else
            read -p "Release version $version to TestFlight? (y/N) " -n 1 -r
        fi
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Release cancelled"
            exit 0
        fi
    fi

    build_archive
    export_archive
    upload_to_testflight

    echo ""
    echo "=========================================="
    echo "  TestFlight Release Complete!"
    echo "=========================================="
    echo ""
    echo "Version: $version (build $build_number)"
    if [ "$SKIP_UPLOAD" = true ]; then
        echo "IPA location: $EXPORT_PATH"
        echo ""
        echo "To upload manually:"
        echo "  xcrun altool --upload-app --type ios --file $EXPORT_PATH/*.ipa \\"
        echo "    --apiKey YOUR_KEY --apiIssuer YOUR_ISSUER"
    else
        echo ""
        echo "The build should appear in TestFlight within a few minutes."
        echo "Check App Store Connect for processing status."
    fi
    echo ""
}

main
