#!/bin/bash
# Copies the gallager-cli skill from the Claude plugin into the Codex
# plugin folder inside the built .app bundle. The skill ships in the
# repo only once (under plugin/gallager/skills/) and is duplicated into
# plugin/codex/gallager/skills/ at build time so both plugins expose it.
#
# Runs after the "Copy Bundle Resources" phase, so the plugin/ tree is
# already in the .app when we get here. We never write into the source
# tree — only into the built product.

set -euo pipefail

APP_PLUGIN_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/plugin"
SOURCE="${APP_PLUGIN_DIR}/gallager/skills/gallager-cli"
DEST_PARENT="${APP_PLUGIN_DIR}/codex/gallager/skills"
DEST="${DEST_PARENT}/gallager-cli"

if [ ! -d "$SOURCE" ]; then
    echo "warning: gallager-cli skill not found at $SOURCE — Codex plugin will ship without it"
    exit 0
fi

mkdir -p "$DEST_PARENT"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
echo "Synced gallager-cli skill into $DEST"
