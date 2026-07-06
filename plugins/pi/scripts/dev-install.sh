#!/usr/bin/env bash
# Dev folder-drop install: copy this source tree into Gallager's plugin dir.
#
# NOTE: Gallager discovers folder-dropped plugins by enumerating real
# subdirectories of ~/.gallager/plugins/ and skips symlinks (Foundation reports a
# symlink-to-dir as isDirectory=false). So this installs a real *copy*. Re-run it
# after editing bin/sidecar or pi-extension/gallager.ts, then relaunch Gallager.
#
#   ./scripts/dev-install.sh            # copy ~/.gallager/plugins/pi  (discoverable)
#   ./scripts/dev-install.sh --symlink  # symlink instead (NOT discovered — debugging only)
#   ./scripts/dev-install.sh --uninstall
#
# After installing, relaunch Gallager (it discovers folder-dropped plugins at
# launch), then `gallager plugin list` shows `pi` (source "folder"). In Settings,
# enable it and click Install to drop the pi extension into
# ~/.pi/agent/extensions/gallager.ts.
set -euo pipefail

ID="pi"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/.gallager/plugins/${ID}"

install_copy() {
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
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
