#!/bin/bash

# Release Script for ClaudeSpy macOS App with Sparkle Auto-Update
# Builds, notarizes, packages, and uploads to the update host over rsync/SSH

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

# Repo plugins (plugins/*) published for remote install
PLUGINS_DIR="$PROJECT_ROOT/plugins"
PLUGINS_BUILD_DIR="$BUILD_DIR/plugins"
PLUGIN_MANIFEST_URLS=()

# Sparkle / update-host configuration. Uploads go over rsync/SSH to the same
# Hetzner box the relay runs on (issue #664), resolved like deploy.sh does:
# DEPLOY_HOST wins, otherwise hcloud looks up HCLOUD_SERVER_NAME.
APPCAST_DIR="$PROJECT_ROOT/docs"
APPCAST_FILE="$APPCAST_DIR/ClaudeSpy.xml"
DEPLOY_USER="${DEPLOY_USER:-root}"
HCLOUD_SERVER_NAME="${HCLOUD_SERVER_NAME:-cleancast}"
UPDATES_REMOTE_DIR="${UPDATES_REMOTE_DIR:-/opt/claudespy-updates}"
DOWNLOAD_URL_PREFIX="https://updates.gallager.app"

# =====================================================
# State gathered during the interactive phase (see gather_user_input).
# Everything the release needs from the user is collected up front so the
# long build/notarize/upload pipeline can run unattended.
# =====================================================
RELEASE_NOTES=""        # macOS appcast release notes (edited)
IOS_WHATS_NEW_FILE=""   # temp file holding iOS TestFlight "What to Test" notes
UPDATES_HOST=""         # update host resolved by verify_updates_host

# =====================================================
# Shared helpers (colors, logging, version + notes editing)
# =====================================================
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

# =====================================================
# Parse arguments
# =====================================================
SKIP_NOTARIZE=false
LOCAL_SIGNING=false
SKIP_UPLOAD=false
BETA=false
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
        --beta)
            BETA=true
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
            echo "Usage: $0 [--skip-notarize] [--local-signing] [--skip-upload] [--beta]"
            exit 1
            ;;
    esac
done

# =====================================================
# Helper functions
# =====================================================
increment_version() {
    local version=$1
    local major minor
    major=$(echo "$version" | cut -d'.' -f1)
    minor=$(echo "$version" | cut -d'.' -f2)
    minor=$((minor + 1))
    echo "$major.$minor"
}

# =====================================================
# Cleanup / rollback support
#
# A single EXIT trap (installed before gather_user_input) so the two concerns
# share one handler instead of clobbering each other:
#   1. Always remove the iOS "What to Test" temp file. It's created up front
#      (before the long unattended pipeline) and handed to testflight.sh, so it
#      must outlive the build/upload steps yet never leak when a step fails.
#   2. Roll back version/appcast commits + the release tag on failure (guarded
#      by REVERT_COMMITS, which stays 0 until the first commit is made).
# =====================================================
REVERT_COMMITS=0
RELEASE_TAG=""

cleanup_on_exit() {
    local exit_code=$?

    if [ -n "$IOS_WHATS_NEW_FILE" ]; then
        rm -f "$IOS_WHATS_NEW_FILE"
    fi

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

    if [ "$BETA" != true ]; then
        if ! command -v create-dmg &> /dev/null; then
            log_error "create-dmg is not installed. Install with: brew install create-dmg"
        fi

        if ! command -v sign_update &> /dev/null; then
            log_warning "Sparkle sign_update not found. Install with: brew install sparkle"
        fi
    fi

    if ! command -v xcrun &> /dev/null; then
        log_error "Xcode command line tools are not installed."
    fi

    if [ "$BETA" != true ] && [[ -n $(git -C "$PROJECT_ROOT" status --porcelain) ]]; then
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
# Package repo plugins (plugins/*) for remote install
# =====================================================
package_plugins() {
    if ! compgen -G "$PLUGINS_DIR/*/plugin.json" > /dev/null; then
        log_info "No plugins found in $PLUGINS_DIR — skipping plugin packaging"
        return
    fi

    for manifest in "$PLUGINS_DIR"/*/plugin.json; do
        local plugin_dir plugin_id
        plugin_dir="$(dirname "$manifest")"
        plugin_id=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$manifest") \
            || log_error "Could not read plugin id from $manifest"

        log_info "Packaging plugin '$plugin_id'..."
        "$SCRIPT_DIR/package-plugin.sh" "$plugin_dir" \
            --base-url "$DOWNLOAD_URL_PREFIX/plugins/$plugin_id" \
            --out "$PLUGINS_BUILD_DIR/$plugin_id" \
            --exclude 'tests/*' --exclude 'scripts/*' \
            || log_error "Packaging failed for plugin '$plugin_id'"

        PLUGIN_MANIFEST_URLS+=("$DOWNLOAD_URL_PREFIX/plugins/$plugin_id/plugin.json")
    done

    log_success "Packaged ${#PLUGIN_MANIFEST_URLS[@]} plugin(s) into $PLUGINS_BUILD_DIR"
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
# Run unit tests
# =====================================================
run_unit_tests() {
    log_info "Running unit tests..."
    "$SCRIPT_DIR/unit-tests.sh" || log_error "Unit tests failed. Fix failing tests before releasing."
    log_success "All unit tests passed"
}

# =====================================================
# Build archive
# =====================================================
build_archive() {
    log_info "Building archive..."

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
      <link>$DOWNLOAD_URL_PREFIX/$(basename "$APPCAST_FILE")</link>
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
# Resolve the update host and verify SSH access
# Runs up front (before the long unattended pipeline) so a missing host or
# broken SSH key setup fails immediately instead of after build/notarize.
# =====================================================
verify_updates_host() {
    if [ "$SKIP_UPLOAD" = true ]; then
        log_info "Skipping update-host check (--skip-upload)"
        return
    fi

    log_info "Resolving update host..."

    if [ -n "$DEPLOY_HOST" ]; then
        UPDATES_HOST="$DEPLOY_HOST"
    elif command -v hcloud &> /dev/null; then
        UPDATES_HOST=$(hcloud server ip "$HCLOUD_SERVER_NAME" 2>/dev/null)
    fi

    if [ -z "$UPDATES_HOST" ]; then
        log_error "Could not determine update host. Set DEPLOY_HOST, or install/configure hcloud (server: $HCLOUD_SERVER_NAME)."
    fi

    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$DEPLOY_USER@$UPDATES_HOST" exit 2>/dev/null; then
        log_error "Cannot connect to $DEPLOY_USER@$UPDATES_HOST over SSH. Make sure SSH key authentication is configured."
    fi

    log_success "Update host reachable: $DEPLOY_USER@$UPDATES_HOST"
}

# =====================================================
# Upload to the update host (rsync over SSH, host from verify_updates_host)
# =====================================================
upload_to_server() {
    local dmg_path=$1

    if [ "$SKIP_UPLOAD" = true ]; then
        log_warning "Skipping upload"
        return
    fi

    local remote_host="$DEPLOY_USER@$UPDATES_HOST"
    log_info "Uploading to $remote_host:$UPDATES_REMOTE_DIR..."

    local dmg_name
    dmg_name=$(basename "$dmg_path")

    ssh -o LogLevel=ERROR "$remote_host" "mkdir -p '$UPDATES_REMOTE_DIR'" \
        || log_error "Could not create $UPDATES_REMOTE_DIR on $UPDATES_HOST"

    # Versioned DMG + appcast.
    rsync -az -e "ssh -o LogLevel=ERROR" \
        "$dmg_path" "$APPCAST_FILE" "$remote_host:$UPDATES_REMOTE_DIR/" \
        || log_error "Upload of DMG/appcast failed"

    # Canonical Gallager.dmg copy, made server-side to avoid a second transfer.
    ssh -o LogLevel=ERROR "$remote_host" \
        "cp '$UPDATES_REMOTE_DIR/$dmg_name' '$UPDATES_REMOTE_DIR/Gallager.dmg'" \
        || log_error "Could not update the canonical Gallager.dmg copy"

    # Mirror packaged plugins (zip + distribution plugin.json per plugin).
    # No --delete: older versioned zips already on the host stay available.
    if [ -d "$PLUGINS_BUILD_DIR" ]; then
        rsync -az -e "ssh -o LogLevel=ERROR" \
            "$PLUGINS_BUILD_DIR/" "$remote_host:$UPDATES_REMOTE_DIR/plugins/" \
            || log_error "Plugin upload failed"
    fi

    # Everything must be world-readable for Caddy's file_server, which runs as
    # its own user (macOS's bundled openrsync has no --chmod, so fix up here).
    ssh -o LogLevel=ERROR "$remote_host" "chmod -R a+rX '$UPDATES_REMOTE_DIR'" \
        || log_error "Could not make $UPDATES_REMOTE_DIR world-readable"

    log_success "Uploaded $dmg_name and $(basename "$APPCAST_FILE") to $UPDATES_HOST"
    log_success "Updated Gallager.dmg link → $dmg_name"
    if [ -d "$PLUGINS_BUILD_DIR" ]; then
        log_success "Uploaded ${#PLUGIN_MANIFEST_URLS[@]} plugin(s) to $UPDATES_REMOTE_DIR/plugins/"
    fi
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
    # Previous release tag to diff against (passed by gather_user_input so mac
    # and iOS notes share one tag). Fall back to the latest tag if unset.
    local previous_tag=$2
    log_info "Generating release notes with Claude..." >&2

    # Check if claude CLI is available
    if ! command -v claude &> /dev/null; then
        log_warning "Claude CLI not found, using generic release notes" >&2
        echo "## What's New in $version

- Bug fixes and improvements"
        return
    fi

    if [ -z "$previous_tag" ]; then
        previous_tag=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")
    fi

    local commit_range
    if [ -n "$previous_tag" ]; then
        commit_range="$previous_tag..HEAD"
        log_info "Analyzing commits from $previous_tag to HEAD" >&2
    else
        commit_range="HEAD~20..HEAD"
        log_info "No previous tag found, analyzing last 20 commits" >&2
    fi

    # Get commit history (--no-merges to match the iOS changelog's commit set)
    local commits
    commits=$(git -C "$PROJECT_ROOT" log "$commit_range" --pretty=format:"- %s (%h)" --no-merges 2>/dev/null || echo "Initial release")

    # Use Claude to generate release notes
    local prompt="You are a technical writer creating release notes for a software product.

Generate professional release notes for version $version of ClaudeSpy, a macOS/iOS app for monitoring Claude Code sessions.

IMPORTANT: This is an independent open source project. It is NOT affiliated with or built by Anthropic.

Here are the commits since the last release:
$commits

Requirements:
- ONLY include changes that directly affect the user experience (new features, behavior changes, bug fixes users would notice, performance improvements)
- SKIP anything that does not affect users: CI/CD changes, build scripts, internal refactoring, code cleanup, dependency updates, tests, docs, tooling, release scripts, server infrastructure changes invisible to users
- If a commit is ambiguous, err on the side of omitting it
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
- If no user-facing changes exist, output only: No user-facing changes in this release.
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
# Prepare macOS appcast release notes (interactive)
# Generates notes with Claude, shows them, and offers an edit.
# Result → RELEASE_NOTES.
# =====================================================
prepare_release_notes() {
    local version=$1
    local prev_tag=$2

    local release_notes
    release_notes=$(generate_release_notes "$version" "$prev_tag")

    echo ""
    echo "Generated release notes:"
    echo "----------------------------------------"
    echo "$release_notes"
    echo "----------------------------------------"
    echo ""

    offer_to_edit_notes "$release_notes" "release notes" "release-notes.md"
    RELEASE_NOTES="$EDITED_NOTES"
}

# =====================================================
# Prepare iOS TestFlight "What to Test" notes (interactive)
# Generates notes with Claude, offers an edit, and writes them to a temp file
# (IOS_WHATS_NEW_FILE) handed to testflight.sh so its iOS step runs unattended.
# =====================================================
prepare_ios_notes() {
    local version=$1
    # Previous release tag, resolved once by gather_user_input and shared with
    # the macOS notes so both diff against the identical tag.
    local prev_tag=$2

    # Only needed when the iOS TestFlight step will actually run.
    if [ "$SKIP_UPLOAD" = true ]; then
        log_info "Skipping iOS 'What to Test' notes (--skip-upload)"
        return
    fi

    local ios_notes
    ios_notes=$(generate_changelog "$version" "$prev_tag")

    echo ""
    echo "Generated iOS 'What to Test' notes:"
    echo "----------------------------------------"
    echo "$ios_notes"
    echo "----------------------------------------"
    echo ""

    offer_to_edit_notes "$ios_notes" "iOS 'What to Test' notes" "what-to-test.txt"
    ios_notes="$EDITED_NOTES"

    IOS_WHATS_NEW_FILE=$(mktemp) || log_error "Could not create temp file for iOS notes"
    printf '%s\n' "$ios_notes" > "$IOS_WHATS_NEW_FILE"
}

# =====================================================
# Gather ALL user interaction up front so the release runs unattended:
# update-host SSH preflight, macOS release notes, and iOS "What to Test" notes.
# =====================================================
gather_user_input() {
    local version=$1

    # Resolve the previous release tag ONCE and hand it to both note
    # generators. These run BEFORE the version bump and the new release tag
    # exist, so this is the latest existing tag. Sharing it avoids a duplicate
    # git call and guarantees the macOS and iOS notes diff against the identical
    # previous tag (and, with --no-merges in both, the identical commit set).
    local prev_tag
    prev_tag=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")

    verify_updates_host
    prepare_release_notes "$version" "$prev_tag"
    prepare_ios_notes "$version" "$prev_tag"

    log_success "All input collected — the rest of the release runs unattended."
}

# =====================================================
# Beta build (build, sign, notarize, copy to ~)
# =====================================================
run_beta_build() {
    echo ""
    echo "=========================================="
    echo "  ClaudeSpy Beta Build"
    echo "=========================================="
    echo ""

    check_prerequisites

    local version
    version=$(get_version)
    local build_number
    build_number=$(get_build_number)
    log_info "Building beta of version $version (build $build_number)"

    rm -rf "$BUILD_DIR"
    build_archive
    export_archive
    verify_bundled_plugin
    notarize_app

    local app_path="$EXPORT_PATH/$APP_NAME.app"
    local dest_path="$HOME/$APP_NAME.app"

    log_info "Copying app to $dest_path..."
    rm -rf "$dest_path"
    cp -R "$app_path" "$dest_path" || log_error "Failed to copy app to $dest_path"

    rm -rf "$BUILD_DIR"

    echo ""
    echo "=========================================="
    echo "  Beta Build Complete!"
    echo "=========================================="
    echo ""
    log_success "Beta app available at $dest_path"
    echo ""
}

# =====================================================
# Main
# =====================================================
main() {
    if [ "$BETA" = true ]; then
        run_beta_build
        exit 0
    fi

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

    # Arm cleanup/rollback now, before gather_user_input creates the iOS notes
    # temp file — so any failure between here and completion removes it. The
    # rollback half stays inert until REVERT_COMMITS is bumped past the first
    # commit below.
    trap cleanup_on_exit EXIT

    # ----------------------------------------------------------------------
    # Interactive phase — collect EVERYTHING we need from the user up front
    # (update-host SSH preflight + macOS/iOS release notes) so the long
    # pipeline below runs unattended and the user can walk away.
    # ----------------------------------------------------------------------
    gather_user_input "$new_version"

    # ----------------------------------------------------------------------
    # Unattended phase — no further user interaction from here on.
    # ----------------------------------------------------------------------

    # Package plugins first — it's fast, so a bad plugin tree aborts the
    # release before the lengthy build/sign/notarize pipeline.
    rm -rf "$BUILD_DIR"
    package_plugins

    run_unit_tests

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

    update_appcast "$version" "$build_number" "$dmg_path" "$sparkle_signature" "$RELEASE_NOTES"

    log_info "Committing appcast..."
    git -C "$PROJECT_ROOT" add "$APPCAST_FILE"
    git -C "$PROJECT_ROOT" commit -m "Update appcast for version $version"
    REVERT_COMMITS=2

    upload_to_server "$dmg_path"

    log_info "Creating release tag v$version..."
    git -C "$PROJECT_ROOT" tag -a "v$version" -m "Release $version"
    RELEASE_TAG="v$version"
    log_success "Tagged release v$version"

    git -C "$PROJECT_ROOT" push
    git -C "$PROJECT_ROOT" push origin "v$version"

    # Release succeeded — disable rollback. The EXIT trap stays armed so it
    # still removes the iOS notes temp file (but skips rollback now that
    # REVERT_COMMITS is 0).
    REVERT_COMMITS=0
    RELEASE_TAG=""

    rm -rf "$BUILD_DIR"

    if [ "$SKIP_UPLOAD" != true ]; then
        echo ""
        log_info "Starting TestFlight release for iOS..."
        # Hand off the pre-generated "What to Test" notes so testflight.sh
        # doesn't prompt — the whole iOS step runs unattended too.
        local testflight_args=(--yes)
        if [ -n "$IOS_WHATS_NEW_FILE" ]; then
            testflight_args+=(--whats-new-file "$IOS_WHATS_NEW_FILE")
        fi
        if "$SCRIPT_DIR/testflight.sh" "${testflight_args[@]}"; then
            log_success "TestFlight release complete"
        else
            log_warning "TestFlight release failed — run '$SCRIPT_DIR/testflight.sh' manually"
        fi
    fi

    # The iOS notes temp file is removed by the EXIT trap (cleanup_on_exit).

    echo ""
    echo "=========================================="
    echo "  Release Complete!"
    echo "=========================================="
    echo ""
    echo "Released: ClaudeSpy $version"
    echo "Download: $DOWNLOAD_URL_PREFIX/$(basename "$dmg_path")"
    echo "Appcast:  $DOWNLOAD_URL_PREFIX/$(basename "$APPCAST_FILE")"
    for manifest_url in "${PLUGIN_MANIFEST_URLS[@]}"; do
        echo "Plugin:   $manifest_url (gallager plugin install $manifest_url)"
    done
    echo ""
}

main
