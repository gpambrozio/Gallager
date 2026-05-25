#!/bin/bash
# Copies every skill from the Claude Code plugin's agent-bundle into the
# Codex agent-bundle inside the built .app. The skills live in the repo
# only once (under
# ClaudeSpyPackage/PluginBundles/claude-code/agent-bundle/gallager/skills/)
# and are mirrored into the Codex bundle's same relative path at build
# time so both plugins expose the same set without keeping a second copy
# in the repo.
#
# Runs after the "Copy Plugin Bundles" phase, so the plugins/ tree is
# already in the .app when we get here. We never write into the source
# tree — only into the built product.

set -euo pipefail

PLUGINS_ROOT="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/plugins"
SOURCE_DIR="${PLUGINS_ROOT}/claude-code/agent-bundle/gallager/skills"
DEST_DIR="${PLUGINS_ROOT}/codex/agent-bundle/gallager/skills"

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
