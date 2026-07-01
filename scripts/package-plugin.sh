#!/usr/bin/env bash
#
# package-plugin.sh — package any Gallager sidecar plugin for distribution.
#
# Reads a plugin source directory (the one containing plugin.json) and produces:
#
#   <out>/<id>-<version>.zip   the bundle — the plugin tree at the ZIP ROOT
#                              (plugin.json + the declared executable + assets),
#                              which is what "Install from Zip…" and a remote
#                              bundle_url both expect.
#   <out>/plugin.json          the DISTRIBUTION manifest (only with --base-url):
#                              a copy of your plugin.json with bundle_url,
#                              bundle_sha256, and manifest_url added. Host this at
#                              your URL — a remote install (Add Plugin from URL /
#                              `gallager plugin install <url>`) needs those fields
#                              or it fails with "missing bundle_url / bundle_sha256".
#
# Usage:
#   scripts/package-plugin.sh <plugin-dir> [--base-url <https-url>] \
#       [--out <dir>] [--exclude <glob>]...
#
# Examples:
#   # Local-zip install only: just the bundle + print its SHA-256.
#   scripts/package-plugin.sh plugins/opencode
#
#   # Remote install: bundle + a ready-to-host distribution plugin.json.
#   # --base-url is where BOTH files will live (no trailing filename):
#   scripts/package-plugin.sh plugins/opencode \
#       --base-url https://updates.gustavo.eng.br/plugins/opencode
#
#   # Trim dev-only files out of the shipped bundle:
#   scripts/package-plugin.sh plugins/opencode --exclude 'tests/*' --exclude 'scripts/*'
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Colors / logging (matches the other scripts in this directory).
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
info()  { printf "${BLUE}==>${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}⚠${NC} %s\n" "$1" >&2; }
die()   { printf "${RED}✗ %s${NC}\n" "$1" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'
    exit "${1:-0}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ----------------------------------------------------------------------------
# Parse arguments.
# ----------------------------------------------------------------------------
PLUGIN_DIR=""
BASE_URL=""
OUT_DIR=""
EXTRA_EXCLUDES=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --base-url) [ $# -ge 2 ] || die "--base-url needs a value"; BASE_URL="$2"; shift 2 ;;
        --out)      [ $# -ge 2 ] || die "--out needs a value"; OUT_DIR="$2"; shift 2 ;;
        --exclude)  [ $# -ge 2 ] || die "--exclude needs a value"; EXTRA_EXCLUDES+=("$2"); shift 2 ;;
        --*)        die "Unknown option: $1 (see --help)" ;;
        *)
            [ -z "$PLUGIN_DIR" ] || die "Unexpected extra argument: $1"
            PLUGIN_DIR="$1"; shift ;;
    esac
done

[ -n "$PLUGIN_DIR" ] || usage 1
command -v python3 >/dev/null || die "python3 is required (used to read/merge plugin.json)"
command -v zip     >/dev/null || die "zip is required"
command -v unzip   >/dev/null || die "unzip is required"
command -v shasum  >/dev/null || die "shasum is required"

# Resolve the plugin dir to an absolute path (keep the original for the error).
_RESOLVED="$(cd "$PLUGIN_DIR" 2>/dev/null && pwd)" || die "Plugin directory not found: $PLUGIN_DIR"
PLUGIN_DIR="$_RESOLVED"
MANIFEST="$PLUGIN_DIR/plugin.json"
[ -f "$MANIFEST" ] || die "No plugin.json at the plugin root: $MANIFEST"

# ----------------------------------------------------------------------------
# Read manifest fields (id, version, runtime, executable, icon).
# ----------------------------------------------------------------------------
FIELDS="$(python3 - "$MANIFEST" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("plugin.json is not valid JSON: %s\n" % e)
    sys.exit(2)
if not isinstance(m, dict):
    sys.stderr.write("plugin.json must be a JSON object\n"); sys.exit(2)
sc = m.get("sidecar") or {}
ui = m.get("ui") or {}
print(m.get("id", ""))
print(m.get("version", ""))
print(m.get("runtime", ""))
print(sc.get("executable") or "bin/sidecar")
print(ui.get("icon") or "")
PY
)" || die "Could not read $MANIFEST"

# mapfile, not `read`: command substitution strips the trailing newline, so an
# empty last field (e.g. no icon) would drop a line and misalign a 5-var read.
# An unset trailing array index expands to "" — exactly the right default.
mapfile -t _FIELDS <<< "$FIELDS"
PLUGIN_ID="${_FIELDS[0]:-}"
PLUGIN_VERSION="${_FIELDS[1]:-}"
PLUGIN_RUNTIME="${_FIELDS[2]:-}"
PLUGIN_EXEC="${_FIELDS[3]:-bin/sidecar}"
PLUGIN_ICON="${_FIELDS[4]:-}"

# ----------------------------------------------------------------------------
# Validate — mirrors what Gallager enforces at install/discovery time, so a
# bundle this script blesses will pass tree validation.
# ----------------------------------------------------------------------------
[ -n "$PLUGIN_ID" ]      || die "plugin.json is missing \"id\""
[ -n "$PLUGIN_VERSION" ] || die "plugin.json is missing \"version\""

# id sanitizer: ^[a-z0-9][a-z0-9._-]*$, no "..", <= 128 chars.
if ! [[ "$PLUGIN_ID" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || [[ "$PLUGIN_ID" == *".."* ]] || [ "${#PLUGIN_ID}" -gt 128 ]; then
    die "Invalid plugin id \"$PLUGIN_ID\" (must match ^[a-z0-9][a-z0-9._-]*\$, no '..', <=128 chars)"
fi

[ "$PLUGIN_RUNTIME" = "sidecar" ] || warn "runtime is \"$PLUGIN_RUNTIME\" (expected \"sidecar\"); Gallager only installs sidecar plugins from a URL/zip."

EXEC_PATH="$PLUGIN_DIR/$PLUGIN_EXEC"
[ -f "$EXEC_PATH" ] || die "Declared executable is missing: $PLUGIN_EXEC"
[ -x "$EXEC_PATH" ] || die "Declared executable is not executable (chmod +x \"$PLUGIN_EXEC\"): $PLUGIN_EXEC"

if [ -n "$PLUGIN_ICON" ] && [ ! -f "$PLUGIN_DIR/$PLUGIN_ICON" ]; then
    die "Declared ui.icon is missing from the bundle: $PLUGIN_ICON"
fi

info "Packaging plugin \"$PLUGIN_ID\" v$PLUGIN_VERSION"
ok   "manifest: $MANIFEST"
ok   "executable: $PLUGIN_EXEC (+x)"
[ -n "$PLUGIN_ICON" ] && ok "icon: $PLUGIN_ICON"

# ----------------------------------------------------------------------------
# Resolve output paths.
# ----------------------------------------------------------------------------
if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$REPO_ROOT/build/plugins/$PLUGIN_ID"   # build/ is gitignored
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

ZIP_NAME="$PLUGIN_ID-$PLUGIN_VERSION.zip"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"

# ----------------------------------------------------------------------------
# Build the zip in a temp dir (never inside the source tree, so the archive can
# never accidentally include itself), then move it into place.
# ----------------------------------------------------------------------------
# Default excludes: VCS / OS / language caches / build output. The plugin's own
# runtime files (bin/, opencode-bridge/, …) are always kept. Trim more with
# --exclude '<glob>'.
EXCLUDES=(
    '.git/*' '*/.git/*' '.git'
    '.gitignore' '.DS_Store' '*/.DS_Store'
    '__pycache__/*' '*/__pycache__/*' '*.pyc'
    '.mypy_cache/*' '*/.mypy_cache/*'
    '.pytest_cache/*' '*/.pytest_cache/*'
)
EXCLUDES+=("${EXTRA_EXCLUDES[@]}")

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_ZIP="$TMP_DIR/$ZIP_NAME"

# -r recurse, -X drop uid/gid/times (keeps the unix mode → executable bit),
# -q quiet. Names are stored relative to the plugin dir, so plugin.json lands at
# the archive root.
( cd "$PLUGIN_DIR" && zip -r -X -q "$TMP_ZIP" . -x "${EXCLUDES[@]}" ) || die "zip failed"

rm -f "$ZIP_PATH"
mv "$TMP_ZIP" "$ZIP_PATH"

# ----------------------------------------------------------------------------
# Verify the archive the same way the installer will: plugin.json at the root
# and the executable present WITH its executable bit intact.
# ----------------------------------------------------------------------------
# Capture the name listing first, then match — piping `unzip … | grep -q` would
# let grep close the pipe on its first hit and hand unzip a SIGPIPE, which
# `set -o pipefail` then reports as a (spurious) failure.
ZIP_NAMES="$(unzip -Z1 "$ZIP_PATH")"
grep -qx 'plugin.json' <<< "$ZIP_NAMES" || die "plugin.json is not at the zip root (internal error)"

VERIFY_DIR="$TMP_DIR/verify"
mkdir -p "$VERIFY_DIR"
unzip -q -o "$ZIP_PATH" "$PLUGIN_EXEC" -d "$VERIFY_DIR" 2>/dev/null || die "executable missing from archive: $PLUGIN_EXEC"
[ -x "$VERIFY_DIR/$PLUGIN_EXEC" ] || die "executable bit was lost in the archive for $PLUGIN_EXEC — cannot ship"

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
SIZE_BYTES="$(wc -c < "$ZIP_PATH" | tr -d ' ')"

ok "bundle: $ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'), $SIZE_BYTES bytes)"
ok "sha256: $SHA256"

# ----------------------------------------------------------------------------
# Distribution manifest (only when a base URL is given).
# ----------------------------------------------------------------------------
if [ -n "$BASE_URL" ]; then
    case "$BASE_URL" in
        https://*) ;;
        *) die "--base-url must be https:// (Gallager rejects non-HTTPS): $BASE_URL" ;;
    esac
    BASE_URL="${BASE_URL%/}"   # strip a trailing slash
    BUNDLE_URL="$BASE_URL/$ZIP_NAME"
    MANIFEST_URL="$BASE_URL/plugin.json"
    OUT_MANIFEST="$OUT_DIR/plugin.json"

    python3 - "$MANIFEST" "$OUT_MANIFEST" "$BUNDLE_URL" "$SHA256" "$MANIFEST_URL" <<'PY' || die "could not write distribution manifest"
import json, sys
src, out, burl, sha, murl = sys.argv[1:6]
m = json.load(open(src))
m["bundle_url"] = burl
m["bundle_sha256"] = sha
m["manifest_url"] = murl
with open(out, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY

    ok "manifest: $OUT_MANIFEST"
    echo
    info "Publish (upload BOTH to your host, at the base URL you passed):"
    printf "    %s\n" "$OUT_MANIFEST   ->  $MANIFEST_URL"
    printf "    %s\n" "$ZIP_PATH   ->  $BUNDLE_URL"
    echo
    info "Then install with:"
    printf "    gallager plugin install %s\n" "$MANIFEST_URL"
    printf "    (or Settings ▸ Agents ▸ Add Plugin from URL… → paste %s)\n" "$MANIFEST_URL"
else
    echo
    info "No --base-url given: bundle only (for \"Install from Zip…\")."
    printf "    gallager plugin install --zip %s\n" "$ZIP_PATH"
    echo
    info "For a URL install, re-run with --base-url <https-url> to also emit a"
    info "distribution plugin.json carrying bundle_url + bundle_sha256."
fi
