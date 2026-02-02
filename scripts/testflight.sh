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
CONFIG_FILE="$PROJECT_ROOT/Config/Shared.xcconfig"
EXPORT_OPTIONS="$SCRIPT_DIR/export-options-ios.plist"
BUILD_DIR="$PROJECT_ROOT/build-ios"
ARCHIVE_PATH="$BUILD_DIR/ClaudeSpy.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="ClaudeSpy"
TEAM_ID="XG2WG7U93U"

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

    check_prerequisites

    local version
    version=$(get_version)
    local build_number
    build_number=$(get_build_number)
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
