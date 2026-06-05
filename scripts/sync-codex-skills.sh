#!/bin/bash
# Copies every skill from the Claude plugin into the Codex plugin
# folder inside the built .app bundle. The skills live in the repo only
# once (under plugin/gallager/skills/) and are mirrored into
# plugin/codex/gallager/skills/ at build time so both plugins expose
# the same set without keeping a second copy in the repo.
#
# Runs after the "Copy Bundle Resources" phase, so the plugin/ tree is
# already in the .app when we get here. We never write into the source
# tree — only into the built product.

set -euo pipefail

APP_PLUGIN_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/plugin"
SOURCE_DIR="${APP_PLUGIN_DIR}/gallager/skills"
DEST_DIR="${APP_PLUGIN_DIR}/codex/gallager/skills"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "warning: no skills directory at $SOURCE_DIR — Codex plugin will ship without skills"
    exit 0
fi

mkdir -p "$DEST_DIR"

# rsync mirrors the whole skills tree, dropping any stale skills in the
# destination that no longer exist in the source. The trailing slash on
# SOURCE_DIR is intentional — it tells rsync to copy the contents, not
# the parent directory itself.
rsync -a --delete "$SOURCE_DIR/" "$DEST_DIR/"

# Log what made it across so build output explains itself.
if compgen -G "$DEST_DIR/*" > /dev/null; then
    echo "Synced skills into $DEST_DIR:"
    for entry in "$DEST_DIR"/*; do
        [ -e "$entry" ] && echo "  - $(basename "$entry")"
    done
else
    echo "Source skills directory is empty; nothing to copy."
fi
