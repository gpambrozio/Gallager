#!/bin/bash

# Release Script for ClaudeSpy macOS App with Sparkle Auto-Update
# Builds, notarizes, packages, and uploads to FTP server

set -e

# =====================================================
# CONFIGURATION
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$PROJECT_ROOT/ClaudeSpy.xcworkspace"
SCHEME="ClaudeSpyServer"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
EXPORT_OPTIONS="$SCRIPT_DIR/export-options.plist"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Gallager.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="Gallager"

# Sparkle / FTP configuration
APPCAST_DIR="$PROJECT_ROOT/docs"
APPCAST_FILE="$APPCAST_DIR/ClaudeSpy.xml"
FTP_HOST="gustavo.eng.br"
FTP_REMOTE_DIR="/"
ONEPASSWORD_ITEM="Updates FTP for gustavo.eng.br"
ONEPASSWORD_ACCOUNT="OKIDD7RZWVFWPDPZSBA4O4BSPI"
DOWNLOAD_URL_PREFIX="https://updates.gustavo.eng.br"

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
SKIP_NOTARIZE=false
LOCAL_SIGNING=false
SKIP_UPLOAD=false
NOTARYTOOL_PROFILE="notarytool-profile"
TEAM_ID="XG2WG7U93U"

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        --local-signing)
            LOCAL_SIGNING=true
            SKIP_NOTARIZE=true
            shift
            ;;
        --skip-upload)
            SKIP_UPLOAD=true
            shift
            ;;
        --notarytool-profile)
            NOTARYTOOL_PROFILE="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-notarize] [--local-signing] [--skip-upload]"
            exit 1
            ;;
    esac
done

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

increment_version() {
    local version=$1
    local major minor
    major=$(echo "$version" | cut -d'.' -f1)
    minor=$(echo "$version" | cut -d'.' -f2)
    minor=$((minor + 1))
    echo "$major.$minor"
}

# =====================================================
# Rollback support
# =====================================================
REVERT_COMMITS=0
RELEASE_TAG=""

rollback_on_failure() {
    local exit_code=$?
    if [ $exit_code -eq 0 ] || [ "$REVERT_COMMITS" -eq 0 ]; then
        return
    fi

    echo ""
    log_warning "Release failed — rolling back changes..."

    if [ -n "$RELEASE_TAG" ]; then
        log_info "Removing tag $RELEASE_TAG..."
        git -C "$PROJECT_ROOT" tag -d "$RELEASE_TAG" 2>/dev/null || true
    fi

    # Preserve any local changes the user had before running the release
    local did_stash=false
    if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
        git -C "$PROJECT_ROOT" stash push -m "release-rollback-save" && did_stash=true
    fi

    log_info "Reverting $REVERT_COMMITS commit(s)..."
    git -C "$PROJECT_ROOT" reset --hard "HEAD~$REVERT_COMMITS"

    if [ "$did_stash" = true ]; then
        log_info "Restoring local changes..."
        git -C "$PROJECT_ROOT" stash pop || log_warning "Could not auto-restore local changes — they are saved in git stash"
    fi

    log_info "Rolled back to pre-release state"
}

# =====================================================
# Check prerequisites
# =====================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v lftp &> /dev/null; then
        log_error "lftp is not installed. Install with: brew install lftp"
    fi

    if ! command -v op &> /dev/null; then
        log_error "1Password CLI is not installed. Install with: brew install --cask 1password-cli"
    fi

    if ! command -v create-dmg &> /dev/null; then
        log_error "create-dmg is not installed. Install with: brew install create-dmg"
    fi

    if ! command -v sign_update &> /dev/null; then
        log_warning "Sparkle sign_update not found. Install with: brew install sparkle"
    fi

    if ! command -v xcrun &> /dev/null; then
        log_error "Xcode command line tools are not installed."
    fi

    if [[ -n $(git -C "$PROJECT_ROOT" status --porcelain) ]]; then
        log_warning "Git working directory has uncommitted changes."
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Release cancelled. Please commit or stash changes first."
        fi
    fi

    log_success "All prerequisites satisfied"
}

# =====================================================
# Verify bundled plugin exists in archive
# =====================================================
verify_bundled_plugin() {
    local app_path="$EXPORT_PATH/$APP_NAME.app"
    local plugin_path="$app_path/Contents/Resources/plugin/gallager/.claude-plugin"

    log_info "Verifying bundled plugin..."

    if [ ! -d "$plugin_path" ]; then
        log_error "Bundled plugin not found at $plugin_path. The app cannot be released without the plugin."
    fi

    # Check for required plugin files
    if [ ! -f "$plugin_path/plugin.json" ]; then
        log_error "plugin.json not found in bundled plugin directory."
    fi

    log_success "Bundled plugin verified"
}

# =====================================================
# Build archive
# =====================================================
build_archive() {
    log_info "Building archive..."

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    local build_args=(
        archive
        -skipMacroValidation
        -skipPackagePluginValidation
        -workspace "$WORKSPACE"
        -scheme "$SCHEME"
        -configuration Release
        -archivePath "$ARCHIVE_PATH"
        -quiet
    )

    if [ "$LOCAL_SIGNING" = true ]; then
        build_args+=(CODE_SIGN_IDENTITY="-")
        build_args+=(CODE_SIGN_STYLE="Manual")
    else
        build_args+=(DEVELOPMENT_TEAM="$TEAM_ID")
    fi

    xcodebuild "${build_args[@]}" || log_error "Archive build failed"

    log_success "Archive built successfully"
}

# =====================================================
# Export archive
# =====================================================
export_archive() {
    if [ "$LOCAL_SIGNING" = true ]; then
        log_info "Exporting archive with local signing..."
        mkdir -p "$EXPORT_PATH"
        cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/" \
            || log_error "Failed to copy app from archive"
        log_success "Archive exported successfully (local signing)"
    else
        log_info "Exporting archive with Developer ID signing..."
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportOptionsPlist "$EXPORT_OPTIONS" \
            -exportPath "$EXPORT_PATH" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            -quiet \
            || log_error "Archive export failed"
        log_success "Archive exported successfully"
    fi
}

# =====================================================
# Notarize the app
# =====================================================
notarize_app() {
    if [ "$SKIP_NOTARIZE" = true ]; then
        log_warning "Skipping notarization"
        return
    fi

    log_info "Notarizing app..."

    local app_path="$EXPORT_PATH/$APP_NAME.app"
    local zip_path="$BUILD_DIR/$APP_NAME-notarize.zip"

    ditto -c -k --keepParent "$app_path" "$zip_path"

    xcrun notarytool submit "$zip_path" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait \
        || log_error "Notarization failed. Set up credentials with: xcrun notarytool store-credentials $NOTARYTOOL_PROFILE --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"

    xcrun stapler staple "$app_path" || log_error "Stapling failed"

    rm "$zip_path"

    log_success "App notarized and stapled successfully"
}

# =====================================================
# Create DMG
# =====================================================
create_dmg_package() {
    local version=$1
    local dmg_name="$APP_NAME-$version.dmg"
    local dmg_path="$BUILD_DIR/$dmg_name"
    local app_path="$EXPORT_PATH/$APP_NAME.app"

    log_info "Creating DMG: $dmg_name..." >&2

    rm -f "$dmg_path"

    local dmg_args=(
        --volname "$APP_NAME"
        --window-pos 200 120
        --window-size 600 400
        --icon-size 100
        --icon "$APP_NAME.app" 150 150
        --hide-extension "$APP_NAME.app"
        --app-drop-link 450 150
        --no-internet-enable
    )

    if [ "$SKIP_NOTARIZE" != true ]; then
        dmg_args+=(--notarize "$NOTARYTOOL_PROFILE")
    fi

    create-dmg "${dmg_args[@]}" "$dmg_path" "$app_path" >&2 \
        || log_error "DMG creation failed"

    log_success "DMG created: $dmg_path" >&2
    echo "$dmg_path"
}

# =====================================================
# Sign DMG for Sparkle
# =====================================================
sign_dmg_for_sparkle() {
    local dmg_path=$1

    if ! command -v sign_update &> /dev/null; then
        log_warning "Skipping Sparkle signing (sign_update not installed)" >&2
        return
    fi

    log_info "Signing DMG with Sparkle EdDSA key..." >&2

    local raw_output
    raw_output=$(sign_update "$dmg_path" 2>/dev/null) || {
        log_warning "Sparkle signing failed. Generate keys with: generate_keys" >&2
        return
    }

    local signature
    signature=$(echo "$raw_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

    if [ -z "$signature" ]; then
        log_warning "Could not parse signature from sign_update output" >&2
        return
    fi

    log_success "DMG signed for Sparkle updates" >&2
    echo "$signature"
}

# =====================================================
# Update appcast.xml
# =====================================================
update_appcast() {
    local version=$1
    local build_number=$2
    local dmg_path=$3
    local signature=$4
    local release_notes=$5

    if [ -z "$signature" ]; then
        log_warning "No Sparkle signature provided, skipping appcast update"
        return
    fi

    log_info "Updating appcast.xml..."

    mkdir -p "$APPCAST_DIR"

    local dmg_size
    dmg_size=$(stat -f%z "$dmg_path" 2>/dev/null || stat --printf="%s" "$dmg_path" 2>/dev/null)

    local dmg_name
    dmg_name=$(basename "$dmg_path")

    local download_url="$DOWNLOAD_URL_PREFIX/$dmg_name"
    local pub_date
    pub_date=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

    # Convert markdown to basic HTML
    local html_notes=""
    if [ -n "$release_notes" ]; then
        html_notes=$(echo "$release_notes" | \
            sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | \
            sed -e 's/^## \(.*\)$/<h2>\1<\/h2>/' \
                -e 's/^### \(.*\)$/<h3>\1<\/h3>/' \
                -e 's/^- \(.*\)$/<li>\1<\/li>/' \
                -e 's/\*\*\([^*]*\)\*\*/<strong>\1<\/strong>/g' | \
            awk '
                BEGIN { in_list=0 }
                /<li>/ { if (!in_list) { print "<ul>"; in_list=1 } }
                !/<li>/ && in_list { print "</ul>"; in_list=0 }
                { print }
                END { if (in_list) print "</ul>" }
            ')
    fi

    local item_file
    item_file=$(mktemp)
    cat > "$item_file" << ITEMEOF
      <item>
         <title>Version $version</title>
         <sparkle:version>$build_number</sparkle:version>
         <sparkle:shortVersionString>$version</sparkle:shortVersionString>
         <pubDate>$pub_date</pubDate>
         <description><![CDATA[
$html_notes
         ]]></description>
         <enclosure url="$download_url"
                    sparkle:edSignature="$signature"
                    length="$dmg_size"
                    type="application/octet-stream"/>
      </item>
ITEMEOF

    if [ -f "$APPCAST_FILE" ]; then
        # Check that <language> tag exists before attempting the update
        if ! grep -q "<language>" "$APPCAST_FILE"; then
            log_error "Appcast file exists but missing <language> tag - cannot insert new version"
        fi

        awk '
            /<language>/ { print; getline; while ((getline line < "'"$item_file"'") > 0) print line; }
            { print }
        ' "$APPCAST_FILE" > "$APPCAST_FILE.tmp" && mv "$APPCAST_FILE.tmp" "$APPCAST_FILE"

        # Verify the new version was added
        if ! grep -q "Version $version" "$APPCAST_FILE"; then
            log_error "Failed to add version $version to appcast.xml"
        fi
    else
        cat > "$APPCAST_FILE" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
   <channel>
      <title>ClaudeSpy Updates</title>
      <link>$DOWNLOAD_URL_PREFIX/appcast.xml</link>
      <description>Most recent changes with links to updates.</description>
      <language>en</language>
$(cat "$item_file")
   </channel>
</rss>
EOF
    fi

    rm -f "$item_file"

    if command -v xmllint &> /dev/null; then
        xmllint --noout "$APPCAST_FILE" 2>&1 || log_error "Generated appcast.xml is not valid XML!"
    fi

    log_success "Appcast updated: $APPCAST_FILE"
}

# =====================================================
# Upload to FTP server
# =====================================================
upload_to_ftp() {
    local dmg_path=$1

    if [ "$SKIP_UPLOAD" = true ]; then
        log_warning "Skipping FTP upload"
        return
    fi

    log_info "Uploading to FTP server..."

    # Get credentials from 1Password
    log_info "Retrieving credentials from 1Password..."
    op signin --account "$ONEPASSWORD_ACCOUNT" || log_error "1Password sign-in failed"

    local FTP_USER FTP_PASS
    FTP_USER=$(op item get "$ONEPASSWORD_ITEM" --fields username --account "$ONEPASSWORD_ACCOUNT") \
        || log_error "Failed to get FTP username from 1Password. Create item '$ONEPASSWORD_ITEM' with username and password fields."
    FTP_PASS=$(op item get "$ONEPASSWORD_ITEM" --fields password --reveal --account "$ONEPASSWORD_ACCOUNT") \
        || log_error "Failed to get FTP password from 1Password"

    local dmg_name
    dmg_name=$(basename "$dmg_path")

    # Upload DMG and appcast.xml
    lftp -c "
set ssl:verify-certificate false;
set cmd:fail-exit true;
open ftp://$FTP_USER:$FTP_PASS@$FTP_HOST;
cd $FTP_REMOTE_DIR;
put -O . '$dmg_path';
put -O . '$APPCAST_FILE';
" || log_error "FTP upload failed"

    log_success "Uploaded $dmg_name and appcast.xml to $FTP_HOST"
}

# =====================================================
# Bump version
# =====================================================
bump_version() {
    local current_version=$1
    local new_version
    new_version=$(increment_version "$current_version")

    local current_build
    current_build=$(get_build_number)
    local new_build=$((current_build + 1))

    log_info "Bumping version: $current_version -> $new_version (build $new_build)"

    sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $new_version/" "$CONFIG_FILE"
    sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $new_build/" "$CONFIG_FILE"

    git -C "$PROJECT_ROOT" add "$CONFIG_FILE"
    git -C "$PROJECT_ROOT" commit -m "Bump version to $new_version"

    log_success "Version bumped to $new_version (build $new_build)"
}

# =====================================================
# Generate release notes using Claude
# =====================================================
generate_release_notes() {
    local version=$1
    log_info "Generating release notes with Claude..." >&2

    # Check if claude CLI is available
    if ! command -v claude &> /dev/null; then
        log_warning "Claude CLI not found, using generic release notes" >&2
        echo "## What's New in $version

- Bug fixes and improvements"
        return
    fi

    # Get the previous tag
    local previous_tag
    previous_tag=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")

    local commit_range
    if [ -n "$previous_tag" ]; then
        commit_range="$previous_tag..HEAD"
        log_info "Analyzing commits from $previous_tag to HEAD" >&2
    else
        commit_range="HEAD~20..HEAD"
        log_info "No previous tag found, analyzing last 20 commits" >&2
    fi

    # Get commit history
    local commits
    commits=$(git -C "$PROJECT_ROOT" log "$commit_range" --pretty=format:"- %s (%h)" 2>/dev/null || echo "Initial release")

    # Use Claude to generate release notes
    local prompt="You are a technical writer creating release notes for a software product.

Generate professional release notes for version $version of ClaudeSpy, a macOS/iOS app for monitoring Claude Code sessions.

IMPORTANT: This is an independent open source project. It is NOT affiliated with or built by Anthropic.

Here are the commits since the last release:
$commits

Requirements:
- Group changes by category (Features, Improvements, Bug Fixes) if applicable
- Explain what each change means for users (not just the technical details)
- Keep it concise but informative
- Use markdown formatting
- Maintain a professional, neutral tone throughout
- Do NOT include any commentary, opinions, jokes, or meta-text
- Do NOT include any preamble like 'Here are the release notes'
- Do NOT add any URLs or links
- Do NOT add 'for more information' sections or footer content
- Do NOT assume or mention who built the app
- Output ONLY the release notes content itself"

    local release_notes
    release_notes=$(claude -p "$prompt" 2>/dev/null) || {
        log_warning "Claude failed to generate release notes, using commit list instead" >&2
        release_notes="## What's New in $version

$commits"
    }

    echo "$release_notes"
}

# =====================================================
# Main
# =====================================================
main() {
    echo ""
    echo "=========================================="
    echo "  ClaudeSpy Release Script"
    echo "=========================================="
    echo ""

    check_prerequisites

    local current_version
    current_version=$(get_version)
    local new_version
    new_version=$(increment_version "$current_version")
    log_info "Current version: $current_version — will release as $new_version"

    echo ""
    read -p "Release version $new_version? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Release cancelled"
        exit 0
    fi

    trap rollback_on_failure EXIT
    bump_version "$current_version"
    REVERT_COMMITS=1

    local version
    version=$(get_version)
    local build_number
    build_number=$(get_build_number)
    log_info "Building version $version (build $build_number)"

    build_archive
    export_archive
    verify_bundled_plugin
    notarize_app

    local dmg_path
    dmg_path=$(create_dmg_package "$version")

    local sparkle_signature
    sparkle_signature=$(sign_dmg_for_sparkle "$dmg_path")

    # Generate release notes using Claude
    local release_notes
    release_notes=$(generate_release_notes "$version")

    echo ""
    echo "Generated release notes:"
    echo "----------------------------------------"
    echo "$release_notes"
    echo "----------------------------------------"
    echo ""

    read -p "Proceed with release? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Release cancelled — reverting version bump..."
        local did_stash=false
        if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
            git -C "$PROJECT_ROOT" stash push -m "release-rollback-save" && did_stash=true
        fi
        git -C "$PROJECT_ROOT" reset --hard HEAD~1
        if [ "$did_stash" = true ]; then
            git -C "$PROJECT_ROOT" stash pop || log_warning "Could not auto-restore local changes — they are saved in git stash"
        fi
        REVERT_COMMITS=0
        log_info "Release cancelled"
        exit 0
    fi

    update_appcast "$version" "$build_number" "$dmg_path" "$sparkle_signature" "$release_notes"

    log_info "Committing appcast..."
    git -C "$PROJECT_ROOT" add "$APPCAST_FILE"
    git -C "$PROJECT_ROOT" commit -m "Update appcast for version $version"
    REVERT_COMMITS=2

    upload_to_ftp "$dmg_path"

    log_info "Creating release tag v$version..."
    git -C "$PROJECT_ROOT" tag -a "v$version" -m "Release $version"
    RELEASE_TAG="v$version"
    log_success "Tagged release v$version"

    git -C "$PROJECT_ROOT" push
    git -C "$PROJECT_ROOT" push origin "v$version"

    # Release succeeded — disable rollback
    REVERT_COMMITS=0
    RELEASE_TAG=""
    trap - EXIT

    rm -rf "$BUILD_DIR"

    echo ""
    echo "=========================================="
    echo "  Release Complete!"
    echo "=========================================="
    echo ""
    echo "Released: ClaudeSpy $version"
    echo "Download: $DOWNLOAD_URL_PREFIX/$(basename "$dmg_path")"
    echo "Appcast:  $DOWNLOAD_URL_PREFIX/appcast.xml"
    echo ""
}

main
