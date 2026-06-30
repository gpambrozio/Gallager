#!/usr/bin/env bash
# Dev folder-drop install: copy this source tree into Gallager's plugin dir.
#
# NOTE: Gallager discovers folder-dropped plugins by enumerating real
# subdirectories of ~/.gallager/plugins/ and skips symlinks (Foundation reports a
# symlink-to-dir as isDirectory=false). So this installs a real *copy*. Re-run it
# after editing bin/sidecar or opencode-bridge/gallager.js, then relaunch Gallager.
#
#   ./scripts/dev-install.sh            # copy ~/.gallager/plugins/opencode  (discoverable)
#   ./scripts/dev-install.sh --symlink  # symlink instead (NOT discovered — debugging only)
#   ./scripts/dev-install.sh --uninstall
#
# After installing, relaunch Gallager (it discovers folder-dropped plugins at
# launch), then `gallager plugin list` shows `opencode` (source "folder").
# In Settings, enable it and click Install to drop the opencode bridge into
# ~/.config/opencode/plugin/gallager.js.
set -euo pipefail

ID="opencode"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/.gallager/plugins/${ID}"

install_copy() {
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  # Copy without the dev-only tests/scripts noise the runtime doesn't need, but
  # keep it simple: copy everything, then ensure the executable bit survives.
  cp -R "$SRC" "$DEST"
  chmod +x "$DEST/bin/sidecar"
  echo "copied $SRC -> $DEST"
}

case "${1:-}" in
  --uninstall)
    rm -rf "$DEST"
    echo "removed $DEST"
    exit 0
    ;;
  --symlink)
    mkdir -p "$(dirname "$DEST")"
    rm -rf "$DEST"
    ln -s "$SRC" "$DEST"
    echo "symlinked $DEST -> $SRC"
    echo "WARNING: Gallager does NOT discover symlinked plugin dirs; use the default (copy)."
    ;;
  ""|--copy)
    install_copy
    ;;
  *)
    echo "usage: $0 [--symlink|--uninstall]" >&2
    exit 2
    ;;
esac

echo "sidecar executable: $([ -x "$DEST/bin/sidecar" ] && echo yes || echo NO)"
echo "Now relaunch Gallager and check: gallager plugin list"
