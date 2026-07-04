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
BETA_GROUP_NAME="Beta 1"
ASC_API_BASE="https://api.appstoreconnect.apple.com/v1"

# =====================================================
# Shared helpers (colors, logging, version + notes editing)
# =====================================================
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

# =====================================================
# Parse arguments
# =====================================================
SKIP_UPLOAD=false
EXPORT_ONLY=false
AUTO_YES=false
SET_CHANGELOG=false
SKIP_SUBMIT=false
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
        --skip-submit)
            SKIP_SUBMIT=true
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
            echo "  --skip-submit       Don't assign to $BETA_GROUP_NAME group or submit for beta review"
            echo "  --yes, -y           Skip confirmation prompts (the 'What to Test' edit offer still appears)"
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

find_beta_group_id() {
    local app_id="$1"
    local response
    response=$(asc_get "/betaGroups?filter[app]=${app_id}&fields[betaGroups]=name")
    local group_id
    group_id=$(echo "$response" | python3 -c "
import sys, json
target = sys.argv[1]
d = json.load(sys.stdin)
for item in d.get('data', []):
    if item['attributes'].get('name') == target:
        print(item['id'])
        break
" "$BETA_GROUP_NAME" 2>/dev/null)

    if [ -z "$group_id" ]; then
        log_error "Could not find beta group: $BETA_GROUP_NAME
API response: $response"
    fi
    echo "$group_id"
}

assign_build_to_beta_group() {
    local build_id="$1"
    local group_id="$2"

    local response
    response=$(asc_post "/betaGroups/${group_id}/relationships/builds" \
        "{\"data\":[{\"type\":\"builds\",\"id\":\"${build_id}\"}]}")

    if [ -n "$response" ] && echo "$response" | grep -q '"errors"'; then
        log_error "Failed to assign build to $BETA_GROUP_NAME
API response: $response"
    fi

    log_success "Build assigned to $BETA_GROUP_NAME"
}

submit_for_beta_review() {
    local build_id="$1"

    local response
    response=$(asc_post "/betaAppReviewSubmissions" \
        "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"${build_id}\"}}}}}")

    if echo "$response" | grep -q '"errors"'; then
        if echo "$response" | grep -qiE 'already|in_review|state_invalid'; then
            log_warning "Build appears to be already submitted for beta review"
            return 0
        fi
        log_error "Failed to submit build for beta review
API response: $response"
    fi

    log_success "Build submitted for beta review"
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
# Generate changelog, wait for build to be ready, set What to Test
# =====================================================
WHATS_NEW_SET=false
BETA_REVIEW_SUBMITTED=false

# Arg 1: prompt_user ("true" to prompt before waiting, "false" to skip)
# Returns 0 on success, 1 on failure. Exits 0 if the user cancels at the prompt.
build_changelog_and_set() {
    local prompt_user="$1"

    # Step 1: Generate changelog with Claude up front
    log_info "Generating changelog..."
    local changelog
    changelog=$(generate_changelog)
    if [ -z "$changelog" ]; then
        log_warning "No commits found for changelog"
        return 1
    fi

    echo ""
    echo "Changelog:"
    echo "$changelog"
    echo ""

    # Always offered, even with --yes: editing the notes is an opportunity
    # (Enter skips it), not a confirmation, and release.sh runs us with --yes.
    offer_to_edit_notes "$changelog" "What to Test notes" "what-to-test.txt"
    changelog="$EDITED_NOTES"

    local build_number
    build_number=$(get_build_number)

    if [ "$prompt_user" = true ] && [ "$AUTO_YES" != true ]; then
        read -p "Wait for build $build_number to be ready and set as 'What to Test'? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    # Step 2: Wait for the build to reach VALID
    log_info "Looking up app..."
    local app_id
    app_id=$(find_app_id)

    log_info "Waiting for build $build_number to finish processing on App Store Connect..."
    log_info "(polling every minute — Ctrl+C to stop)"

    local max_attempts=90  # ~90 minutes
    local attempt=0
    local build_id=""
    local last_state=""

    while [ $attempt -lt $max_attempts ]; do
        local response
        response=$(asc_get "/builds?filter[app]=${app_id}&filter[version]=${build_number}&fields[builds]=version,processingState")

        local state
        state=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('data'):
        print(d['data'][0]['attributes']['processingState'])
except Exception:
    pass
" 2>/dev/null)

        if [ "$state" = "VALID" ]; then
            build_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
            log_success "Build $build_number is ready (ID: $build_id)"
            break
        fi

        if [ "$state" != "$last_state" ]; then
            if [ -n "$state" ]; then
                log_info "Build $build_number state: $state"
            else
                log_info "Build $build_number not yet visible on App Store Connect"
            fi
            last_state="$state"
        fi

        sleep 60
        attempt=$((attempt + 1))
    done

    if [ -z "$build_id" ]; then
        log_warning "Build did not reach VALID state after $max_attempts minutes."
        log_warning "Run '$0 --set-changelog' later to retry."
        return 1
    fi

    # Step 3: Set What to Test
    set_whats_new "$build_id" "$changelog"
    WHATS_NEW_SET=true

    # Step 4: Assign to beta group + submit for review
    if [ "$SKIP_SUBMIT" != true ]; then
        log_info "Looking up beta group: $BETA_GROUP_NAME..."
        local group_id
        group_id=$(find_beta_group_id "$app_id")

        log_info "Assigning build to $BETA_GROUP_NAME..."
        assign_build_to_beta_group "$build_id" "$group_id"

        log_info "Submitting build for beta review..."
        submit_for_beta_review "$build_id"
        BETA_REVIEW_SUBMITTED=true
    fi

    return 0
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

        if ! build_changelog_and_set true; then
            log_error "Failed to set changelog for build $build_number"
        fi

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
    if [ "$SKIP_UPLOAD" != true ]; then
        build_changelog_and_set false || true
    fi

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
    elif [ "$WHATS_NEW_SET" = true ]; then
        echo ""
        echo "Build is live on TestFlight with 'What to Test' notes set."
        if [ "$BETA_REVIEW_SUBMITTED" = true ]; then
            echo "Assigned to $BETA_GROUP_NAME and submitted for beta review."
        elif [ "$SKIP_SUBMIT" = true ]; then
            echo "Beta group assignment and review submission skipped (--skip-submit)."
        fi
    else
        echo ""
        echo "Build uploaded but 'What to Test' notes were not set."
        echo "Run '$0 --set-changelog' later to set them."
    fi
    echo ""
}

main
