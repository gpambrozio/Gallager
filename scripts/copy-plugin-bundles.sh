#!/bin/bash
# Mirror the bundled plugin trees into the built .app at
# `Contents/Resources/plugins/<id>/`, and copy the sidecar binaries
# SPM produces into each plugin's `bin/sidecar` slot.
#
# Run as an Xcode "Copy Plugin Bundles" build phase on the
# ClaudeSpyServer target after Frameworks + Resources but before
# "Sync Codex Skills" (which depends on the agent-bundle tree existing
# inside the .app).
#
# We invoke `swift build` directly (rather than wiring the sidecar
# executable products as Xcode SwiftPackageProductDependencies) because
# the sidecar targets transitively depend on the same SPM packages the
# main ClaudeSpyServerFeature library already uses (swift-log,
# swift-dependencies, etc.). Xcode's SPM integration would emit
# duplicate `<package>_PackageProduct.framework` copies, which Xcode
# rejects with "Multiple commands produce". Running `swift build` in
# its own .build/ keeps the two graphs separate.

set -euo pipefail

PLUGIN_SRC="${SRCROOT}/ClaudeSpyPackage/PluginBundles"
PLUGIN_DST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/plugins"
PACKAGE_PATH="${SRCROOT}/ClaudeSpyPackage"

# Map Xcode's CONFIGURATION (Debug/Release) to swift build's
# --configuration flag (debug/release).
SWIFT_CONFIG=$(echo "${CONFIGURATION:-Debug}" | tr '[:upper:]' '[:lower:]')

# Build the sidecar binaries via SPM. Both targets compile to
# `${PACKAGE_PATH}/.build/<arch>-apple-macosx/<config>/<target>` (and
# also into `.build/<config>/<target>` via SPM's symlink). We use the
# `swift build --show-bin-path` output to discover the right directory
# regardless of arch.
echo "Building sidecar executables via swift build (${SWIFT_CONFIG})..."
swift build \
    --package-path "${PACKAGE_PATH}" \
    --configuration "${SWIFT_CONFIG}" \
    --product ClaudeCodePluginSidecar \
    --product CodexPluginSidecar

BIN_PATH=$(swift build \
    --package-path "${PACKAGE_PATH}" \
    --configuration "${SWIFT_CONFIG}" \
    --show-bin-path)

rm -rf "$PLUGIN_DST"
mkdir -p "$PLUGIN_DST"

for plugin_id in claude-code codex; do
    src="$PLUGIN_SRC/$plugin_id"
    dst="$PLUGIN_DST/$plugin_id"
    if [ ! -d "$src" ]; then
        echo "warning: no plugin source at $src — skipping"
        continue
    fi
    mkdir -p "$dst"
    # ditto preserves the executable bit on hook.py and copies
    # everything (manifests, agent-bundle, settings, icons) verbatim.
    ditto "$src/" "$dst/"
done

# Copy the SPM-built sidecar executables into <plugin>/bin/sidecar.
copy_exe() {
    local product="$1"
    local plugin_id="$2"
    local src="$BIN_PATH/$product"
    local dst_dir="$PLUGIN_DST/$plugin_id/bin"
    if [ ! -x "$src" ]; then
        echo "warning: missing executable $src — sidecar for '$plugin_id' will not run"
        return
    fi
    mkdir -p "$dst_dir"
    cp "$src" "$dst_dir/sidecar"
    chmod +x "$dst_dir/sidecar"
}

copy_exe ClaudeCodePluginSidecar claude-code
copy_exe CodexPluginSidecar codex

# Re-stamp the bundled hook bridges as executable in case the source
# tree lost the bit (e.g. a filesystem that doesn't preserve modes).
chmod +x "$PLUGIN_DST/claude-code/agent-bundle/gallager/scripts/hook.py" 2>/dev/null || true
chmod +x "$PLUGIN_DST/codex/agent-bundle/gallager/scripts/hook.py" 2>/dev/null || true

echo "Copied plugin bundles into $PLUGIN_DST"
