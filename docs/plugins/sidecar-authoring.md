# Sidecar Plugin Authoring Guide

This is the durable external contract for building a v2 sidecar plugin for Gallager
(ClaudeSpy Mac app). A sidecar plugin is a standalone executable that Gallager spawns
as a child process and communicates with over stdio using JSON-RPC.

> **Authoring shortcut:** the `gallager` Claude Code plugin bundles a
> `create-agent-plugin` skill (`plugin/gallager/skills/create-agent-plugin/`) that
> scaffolds a working sidecar from a runnable Python template and a self-contained
> copy of this contract. This document remains the source of truth; the skill is the
> guided path.

**Key source files** (read these if you need more detail):
- `ClaudeSpyPackage/Sources/GallagerPluginProtocol/Manifest.swift` — manifest schema
- `ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarWire.swift` — RPC vocabulary + framing
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarSupervisor.swift` — spawn, crash policy
- `ClaudeSpyPackage/Sources/GallagerPluginProtocol/IngressFrame.swift` — hook ingress frame
- `plugin/gallager/scripts/hook.py` — reference hook bridge implementation

---

## 1. Manifest Schema

A sidecar plugin is a directory under `~/.gallager/plugins/<id>/` containing a
`plugin.json` manifest and an executable. Gallager reads `plugin.json` at startup.

### JSON keys (snake_case)

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `schema_version` | integer | no (defaults to 1) | Must be `1` |
| `id` | string | yes | Plugin identifier (see ID rules below) |
| `display_name` | string | yes | Human-readable name shown in Settings |
| `short_name` | string | yes | Short label used in pane badges |
| `version` | string | no (defaults to `"0.0.0"`) | Semver string |
| `process_names` | array of string | no (defaults to `[]`) | Process base-names for pane auto-detection |
| `runtime` | string | yes for sidecar | Must be `"sidecar"` |
| `sidecar.executable` | string | yes for sidecar | Relative path to the binary under the plugin root |
| `sidecar.args` | array of string | no (defaults to `[]`) | Extra arguments passed to the executable |
| `sidecar.default_config_root` | string | no | The agent's default config location (e.g. `"~/.config/opencode"`). Shown as the non-removable root row in the Agents settings tab; falls back to `~` when absent. Presentational only — the default row still calls `install` with `configRoot: null`. |
| `ui.icon` | string | no | Relative path to an icon asset (e.g. `"assets/icon.png"`) |
| `ui.color` | string | no | Accent color hex (e.g. `"#4A90E2"`); defaults to `"#888888"` |
| `publisher` | string | no | Human-readable publisher name |
| `manifest_url` | string (URL) | no | HTTPS URL of this manifest (set by the registry for remote installs) |
| `bundle_url` | string (URL) | no | HTTPS URL of the zip bundle (required for remote install) |
| `bundle_sha256` | string | no | Lowercase hex SHA-256 of the bundle zip (required for remote install) |
| `signature` | string | no | Reserved for future code-signing; currently ignored |
| `capabilities.rich_pane_detection` | boolean | no (defaults to false) | Opt in to the `detect_pane` RPC |
| `capabilities.modal_prompts` | boolean | no (defaults to false) | Opt in to the `prompt_user` notification |

### Example manifest

```json
{
  "schema_version": 1,
  "id": "my-agent",
  "display_name": "My Agent",
  "short_name": "myagent",
  "version": "1.0.0",
  "process_names": ["my-agent-cli"],
  "runtime": "sidecar",
  "sidecar": {
    "executable": "bin/sidecar",
    "args": ["--log-level", "info"]
  },
  "ui": {
    "icon": "assets/icon.png",
    "color": "#4A90E2"
  },
  "publisher": "Your Name"
}
```

### ID rules

The `id` field is used as a filesystem path component. It must pass all of:

- Matches the regex `^[a-z0-9][a-z0-9._-]*$` (lowercase letters, digits, `.`, `_`, `-`; first character must be a letter or digit)
- Does not contain `..` (no directory traversal)
- Length ≤ 128 characters

The directory name under `~/.gallager/plugins/` must exactly equal `id`. Gallager rejects
any folder where `sanitize(id)` does not match the directory name.

---

## 2. Stdio JSON-RPC Transport

Gallager communicates with the sidecar over the process's `stdin`/`stdout` using
LSP-style Content-Length framing.

> **Key casing — read this first.** The stdio transport serializes its Swift wire
> structs with a plain encoder (no key-strategy), so **every JSON key on this
> channel is camelCase** (`pluginID`, `sessionID`, `tmuxPane`, `pluginRoot`,
> `paneID`, …). This is the opposite of the two snake_case channels: the
> `plugin.json` manifest (Section 1) and the hook **ingress socket** frame
> (Section 4, where the key is `plugin_id`). A snake_case key in a `translate_event`
> reply (e.g. `plugin_id` or `session_id`) is silently dropped. When in doubt: the
> JSON your sidecar reads from / writes to stdio is camelCase.

### Frame format

Each message (in either direction) is preceded by a header:

```
Content-Length: <byte-count>\r\n
\r\n
<JSON body>
```

- The header is ASCII, terminated by `\r\n\r\n`.
- `Content-Length` is the byte count of the JSON body only (not including the header).
- Gallager enforces a maximum header size of 16 KiB and a maximum body size of 32 MiB.

**This framing is only for the stdio transport.** The hook ingress socket uses a
different format (4-byte big-endian length prefix — see Section 4).

### Message envelope

Every message is a JSON object with these fields:

| Field | Type | Present on |
|-------|------|------------|
| `id` | string | requests and their responses |
| `method` | string | requests and notifications |
| `params` | any JSON value | requests and notifications |
| `result` | any JSON value | successful responses |
| `error` | `{code, message}` | error responses |

Rules:
- **Request**: `id` + `method` both present.
- **Notification**: `method` present, `id` absent. No response is sent.
- **Response**: `id` present, `method` absent. Must echo the exact `id` of the request it answers.

**Responses MUST echo the request `id`.** A response whose `id` does not match any
pending request is silently discarded by Gallager.

An error response looks like:

```json
{
  "id": "abc-123",
  "error": { "code": "method_not_found", "message": "Unknown method: foo" }
}
```

### App → Sidecar methods (App sends, Sidecar responds)

These are all **requests** (Gallager expects a response for each):

| Method | Description |
|--------|-------------|
| `initialize` | Sent once at startup. `params` is a serialized `PluginEnvWire` object (see below). The sidecar must respond before Gallager considers it ready. |
| `translate_event` | Deliver a hook event. `params` is an `IngressFrameWire` object: `{pluginID, context, payload}` (camelCase `pluginID` — note this differs from the snake_case `plugin_id` your hook writes to the ingress socket in Section 4). |
| `deliver_response` | Deliver the result of a `prompt_user` request (when `capabilities.modal_prompts` is true). |
| `refresh_projects` | Ask the sidecar to rescan and re-emit its project list. |
| `command_for_launch` | Ask for the launch command to start the agent in a new pane. Returns a `{command, args, env}` object. |
| `install` | Ask the sidecar to install the agent's plugin into the agent's own config (e.g. `.claude/` hooks). |
| `uninstall` | Ask the sidecar to remove the agent's plugin from the config. |
| `install_status` | Ask whether the agent's plugin is installed. |
| `apply_settings` | Deliver updated settings JSON. `params` contains the new settings value. |
| `shutdown` | Graceful shutdown signal. The sidecar should flush state and exit. Gallager follows with SIGTERM after 5 seconds, then SIGKILL. |
| `detect_pane` | Only sent when `capabilities.rich_pane_detection` is true. `params` is a `SidecarPaneInfo` object: `{paneID, processNames, command, cwd}`. Returns a `SidecarPaneMatch`: `{matches, projectPath, sessionID}`. |

#### `PluginEnvWire` (params for `initialize`)

```json
{
  "pluginRoot": "/path/to/plugin/dir",
  "stateDir": "/path/to/state/dir",
  "appVersion": "2.4.0",
  "settings": {},
  "marketplaceSource": "/path/to/marketplace/assets",
  "otlpReceiverEndpoint": "http://127.0.0.1:24318"
}
```

`otlpReceiverEndpoint` is `null` when no OTLP receiver is running. The port is
whatever the receiver actually bound this launch (it probes fallback candidates
when its preferred port is taken) — use the value verbatim, never assume a
fixed port. `settings` is the current settings object (or `{}` when empty).
(camelCase keys — this is the stdio transport; see the casing note at the top
of this section.)

### Sidecar → App messages

#### Notifications (Sidecar sends, no response expected)

| Method | Description |
|--------|-------------|
| `set_projects` | Inform the app of the current project list. `params` is an array of project objects. |
| `emit_event` | Emit a plugin event to the app (e.g. a session state change). |
| `send_text` | Ask the app to type text into the currently focused pane. |
| `send_keys` | Ask the app to send key sequences to the currently focused pane. |
| `log` | Write a log line to the plugin's sidecar log. `params`: `{level, message}` where `level` is one of `"debug"`, `"info"`, `"warn"`, `"error"`. |
| `prompt_user` | Only valid when `capabilities.modal_prompts` is true. Asks Gallager to show a modal dialog. `params`: `{title, message?}`. Gallager responds via a `deliver_response` request. |

#### Requests (Sidecar sends, App responds)

| Method | Description |
|--------|-------------|
| `agent_panes` | Ask the app which tmux pane IDs belong to this plugin's agent. Returns an array of pane ID strings. |

### Unrecognized methods

Gallager responds to any unrecognized request with:

```json
{
  "id": "<echo>",
  "error": { "code": "method_not_found", "message": "Unknown method: <name>" }
}
```

The sidecar should do the same for unrecognized methods it receives.

---

## 3. Spawn Environment

When Gallager spawns the sidecar executable it inherits the full parent process
environment and adds these five plugin-specific variables:

| Variable | Example | Description |
|----------|---------|-------------|
| `GALLAGER_PLUGIN_ROOT` | `/Users/you/.gallager/plugins/my-agent` | Absolute path to the plugin bundle directory (read-only assets). |
| `GALLAGER_STATE_DIR` | `/Users/you/.gallager/state/plugins/my-agent` | Writable per-plugin state/scratch directory. |
| `GALLAGER_APP_VERSION` | `2.4.0` | The host app's marketing version string. |
| `GALLAGER_INGRESS_SOCK` | `/Users/you/.gallager/state/ingress.sock` | Unix domain socket path for the hook ingress channel (see Section 4). |
| `GALLAGER_PLUGIN_ID` | `my-agent` | The plugin's `id` from its manifest. |

The sidecar's current working directory is set to `GALLAGER_PLUGIN_ROOT`.

---

## 4. Hook Ingress (for hook-based agents)

If your agent uses hook scripts (like Claude Code's `PostToolUse` hooks or Codex CLI's
hooks), those scripts connect to the ingress socket to forward events into Gallager.
Your sidecar's `install` implementation should template `GALLAGER_INGRESS_SOCK` and
`GALLAGER_PLUGIN_ID` into a hook bridge script.

### Ingress frame format

The ingress socket uses a **4-byte big-endian length prefix**, NOT Content-Length framing.
This is different from the stdio transport.

```
[UInt32 big-endian byte count] [JSON body bytes]
```

The JSON body is:

```json
{
  "plugin_id": "my-agent",
  "context": {
    "TMUX_PANE": "%4",
    "CLAUDE_PROJECT_DIR": "/path/to/project"
  },
  "payload": { ... }
}
```

- `plugin_id`: the plugin id (matches `GALLAGER_PLUGIN_ID`)
- `context`: string-keyed string-valued env snapshot; `TMUX_PANE` must be present for routing
- `payload`: the raw hook event object

### Reference Python bridge

```python
import json, os, socket, struct, sys

PLUGIN_ID = os.environ.get("GALLAGER_PLUGIN_ID", "my-agent")
SOCKET_PATH = os.environ.get("GALLAGER_INGRESS_SOCK",
                             os.path.expanduser("~/.gallager/state/ingress.sock"))

tmux_pane = os.environ.get("TMUX_PANE", "")
if not tmux_pane:
    sys.exit(0)  # Not inside tmux — nothing to route.

raw = sys.stdin.read()
try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    sys.exit(0)

context = {"TMUX_PANE": tmux_pane}
project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
if project_dir:
    context["CLAUDE_PROJECT_DIR"] = project_dir

body = json.dumps({"plugin_id": PLUGIN_ID, "context": context, "payload": payload}).encode()
frame = struct.pack(">I", len(body)) + body

try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall(frame)
except Exception:
    pass  # Gallager not running — drop silently.
```

**Platform note:** `socket.AF_UNIX` is available in Python 3.9+ on macOS and Linux.
For a shell-script bridge using `nc`: on macOS/BSD use `nc -U <path>`; on Linux with
GNU netcat use `nc --unixsock <path>` (the `-U` flag is BSD-only).

---

## 5. Lifecycle and Crash Policy

### Startup

1. Gallager spawns the executable with the spawn environment described in Section 3.
2. Gallager immediately sends an `initialize` request with the `PluginEnvWire` payload.
3. The sidecar must respond to `initialize` before any other requests are sent.
4. Gallager closes its copies of the child-inherited pipe ends after spawning
   (`stdin.fileHandleForReading`, `stdout.fileHandleForWriting`, `stderr.fileHandleForWriting`).

### Supervised restarts

Gallager supervises the sidecar. On unexpected exit (not triggered by a `stop()` call):

1. The crash is recorded with a timestamp.
2. Crashes are counted in a rolling 60-second window.
3. The sidecar is restarted after a backoff: 1 s (1st crash), 2 s (2nd), 4 s (3rd+).
4. On the 4th crash within the 60-second window the plugin is **auto-disabled**.
   The last 50 lines of stderr are collected for the crash-loop banner.

**After any restart, Gallager re-sends `initialize`.** Your sidecar must be prepared to
receive a fresh `initialize` at any point and treat it as a clean-slate startup.

### Shutdown

On graceful shutdown Gallager:
1. Sends a `shutdown` request.
2. Waits for the sidecar to exit.
3. Sends SIGTERM after 5 seconds if the process is still running.
4. Sends SIGKILL after another 5 seconds if still running.

### Stderr logging

The sidecar's stderr is captured and written to:

```
~/.gallager/state/plugins/<id>/logs/stderr.log
```

This file is rotated at 5 MB (one generation kept as `stderr.log.1`). Stderr is
separate from structured log lines written via the `log` notification, which go to
`sidecar.log` (the structured log file).

---

## 6. Telemetry (Optional)

If your agent supports OpenTelemetry, you can point its OTLP exporter at the
`otlpReceiverEndpoint` value received in the `initialize` params. Gallager runs a
local OTLP/JSON receiver on the IPv4 loopback (`http://127.0.0.1:<port>`, default
port `24318` but not guaranteed — always use the endpoint value as received) when
active.

**Caveat:** The built-in OTLP accumulator currently only parses event namespaces
`claude_code.*` and `codex.*`. OTLP payloads from a third-party agent that use a
different event namespace are silently dropped today. Supporting arbitrary agent
namespaces is a v2.x follow-on.

---

## 7. Distribution

### Packaging (both modes)

`scripts/package-plugin.sh <plugin-dir>` builds the bundle for you — it validates
the tree the same way Gallager will (manifest at the root, declared executable
present *and* executable, declared `ui.icon` present), zips the plugin tree at the
archive root, and prints the SHA-256. Add `--base-url <https-url>` (where both files
will be hosted, no filename) and it also emits a ready-to-host distribution
`plugin.json` with `bundle_url` / `bundle_sha256` / `manifest_url` filled in. Output
lands in `build/plugins/<id>/` (gitignored); trim dev-only files with
`--exclude '<glob>'`. Run `scripts/package-plugin.sh --help` for details.

### Remote install (recommended)

Host a `plugin.json` manifest at an HTTPS URL with these additional fields:

```json
{
  "bundle_url": "https://example.com/my-agent-1.0.0.zip",
  "bundle_sha256": "abcdef0123456789...",
  "manifest_url": "https://example.com/plugin.json"
}
```

The bundle must be a zip archive whose root contains `plugin.json` and the executable.

Users install via:
- **Settings UI:** "Add Plugin from URL…" — paste the manifest URL
- **CLI:** `gallager plugin install https://example.com/plugin.json`

Install flow (enforced by Gallager):
1. Fetch the manifest over HTTPS. Non-`https://` URLs are rejected.
2. Validate `schema_version == 1`, id sanitization passes.
3. Present a trust confirmation dialog showing publisher, id, version, and bundle URL.
4. Download the bundle zip mid-stream (capped at 50 MiB).
5. Verify SHA-256 digest against `bundle_sha256` (case-insensitive hex comparison).
6. Unpack into a staging directory and perform zip-slip hardening (every extracted
   path is checked against the staging root after symlink resolution).
7. Validate the extracted tree: `plugin.json` present, `id` and `version` match the
   manifest, declared executable exists and has the executable bit.
8. Atomic commit (rename staging → final).

### Local zip install

Ship the plugin as a self-contained `.zip` whose **root** contains `plugin.json` and
the executable (the same archive layout as the remote `bundle_url`). No `manifest_url`,
`bundle_url`, or `bundle_sha256` is needed — the manifest lives inside the zip.

Users install via:
- **Settings UI:** Agents tab → "Install from Zip…" — pick the `.zip` in the open panel.
- **CLI:** `gallager plugin install --zip <path>` (add `--yes` to skip the trust prompt).

Install flow (enforced by Gallager):
1. Peek `plugin.json` at the archive root (no extraction yet) and validate
   `schema_version == 1` + id sanitization.
2. Present the same trust confirmation dialog (showing publisher, id, version, the
   local file path, and the on-disk size — no SHA-256, since integrity pinning is moot
   for a file the user picked).
3. On confirm: unpack into a staging directory with the same zip-slip hardening and
   tree validation as the remote flow, then atomic-commit (rename staging → final).

The plugin is registered with **source `folder`** — it lives in `~/.gallager/plugins/<id>/`
exactly like a folder-dropped plugin, so the next launch re-discovers it the same way.
There is no update channel for a zip-installed plugin (no `manifest_url`); reinstall a
newer zip to upgrade.

### Folder-drop install

Copy the plugin directory directly into `~/.gallager/plugins/<id>/`. Gallager discovers
it on the next launch. Requirements:
- Directory name must equal the manifest's `id` (after sanitization).
- `plugin.json` must decode successfully with `runtime == "sidecar"`.
- The executable declared in `sidecar.executable` (or `bin/sidecar` if absent) must exist and be executable.

### Updates

```
gallager plugin update <id>
```

Fetches the manifest from the stored `manifest_url`, repeats the download/verify/unpack
flow, and atomically replaces the installed directory. The update checker does not
currently send `If-None-Match` (a v2.x follow-on).

### Uninstall

```
gallager plugin uninstall <id>
```

Calls the sidecar's `uninstall` RPC (which removes hook files from agent config
directories), disables the plugin, and deletes the install directory. Optionally
deletes the state directory when `--delete-state` is passed.

---

## 8. Minimal Example: Plugin Directory Layout

```
~/.gallager/plugins/my-agent/
├── plugin.json              # manifest
├── bin/
│   └── sidecar              # executable (chmod +x)
└── assets/
    └── icon.png             # optional icon
```

### Minimal working sidecar (Python)

```python
#!/usr/bin/env python3
"""Minimal Gallager sidecar — handles initialize/shutdown, ignores everything else."""
import json, sys

def read_message():
    header = b""
    while b"\r\n\r\n" not in header:
        ch = sys.stdin.buffer.read(1)
        if not ch:
            return None
        header += ch
    length = int([line.split(b":")[1].strip()
                  for line in header.split(b"\r\n")
                  if line.lower().startswith(b"content-length")][0])
    return json.loads(sys.stdin.buffer.read(length))

def send_message(msg):
    body = json.dumps(msg).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
    sys.stdout.buffer.flush()

while True:
    msg = read_message()
    if msg is None:
        break
    if msg.get("id") and msg.get("method"):  # request
        method = msg["method"]
        if method == "shutdown":
            send_message({"id": msg["id"], "result": {}})
            break
        else:
            send_message({"id": msg["id"], "result": {}})
```

---

## 9. Security Model

**Honest scope:** Gallager v2 provides **trusted-on-install, hash-pinned, runs with
your permissions** security — not "safe to run untrusted plugins."

What the v2 security model does:
- **Transport integrity:** manifests and bundles are fetched over `https://` only.
- **Hash pinning:** the downloaded bundle's SHA-256 is verified against the value in
  the manifest before extraction. This is an **integrity** check (the bits you asked
  for are the bits you got) — not an **authenticity** check (it does not prove who
  created the bundle).
- **Explicit trust prompt:** the user sees publisher, id, version, and bundle URL and
  must confirm before any download begins.
- **Zip-slip hardening:** all extracted paths are checked against the staging root
  (including symlink resolution) before the bundle is committed.

What the v2 security model does NOT do:
- **No code signing or publisher identity verification.** The `signature` field in the
  manifest is reserved but not checked.
- **No OS sandbox.** The sidecar runs as the user with full filesystem, network, and
  process permissions.
- **No marketplace vetting.** There is no centralized review process.

Do not run plugins from untrusted sources.

---

## 10. Known Limitations and Follow-ups

- **`rich_pane_detection`:** The `detect_pane` RPC types (`SidecarPaneInfo`,
  `SidecarPaneMatch`) are implemented and the manifest capability flag is read, but the
  call-site wiring in the pane-detection coordinator is a v2.x follow-on. Declare the
  capability in your manifest now — the wiring will be added without a manifest change.
- **`modal_prompts`:** The `prompt_user` notification and `deliver_response` RPC types
  are implemented behind the manifest flag, but the modal UI in the Mac app is a v2.x
  follow-on.
- **Crash-loop banner:** When a plugin is auto-disabled after 4 crashes in 60 seconds,
  the crash details are collected but the Settings UI banner is a v2.x follow-on.
- **Update checker `If-None-Match`:** The update flow does not yet send `If-None-Match`
  to avoid redundant downloads on unchanged manifests. A v2.x follow-on.
- **Third-party OTLP namespaces:** As noted in Section 6, event namespaces other than
  `claude_code.*` and `codex.*` are silently dropped by the current accumulator.
