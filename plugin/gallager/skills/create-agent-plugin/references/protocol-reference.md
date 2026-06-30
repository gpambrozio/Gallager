# Gallager Sidecar Plugin — Protocol Reference

The durable external contract for a v2 **sidecar plugin**: a standalone executable
Gallager (the ClaudeSpy Mac app) spawns as a child process and drives over stdio
with JSON-RPC. This file is self-contained — you do not need the ClaudeSpy source
to build a plugin against it.

## Contents

1. [Three wire casings (read this first)](#1-three-wire-casings-read-this-first)
2. [Plugin layout & manifest schema](#2-plugin-layout--manifest-schema)
3. [Stdio JSON-RPC transport](#3-stdio-json-rpc-transport)
4. [App → Sidecar requests](#4-app--sidecar-requests)
5. [Sidecar → App messages](#5-sidecar--app-messages)
6. [PluginEvent & AgentState (the heart)](#6-pluginevent--agentstate-the-heart)
7. [Spawn environment](#7-spawn-environment)
8. [Hook ingress channel](#8-hook-ingress-channel)
9. [Lifecycle & crash policy](#9-lifecycle--crash-policy)
10. [Distribution](#10-distribution)
11. [Security model](#11-security-model)
12. [Known limitations](#12-known-limitations)

---

## 1. Three wire casings (read this first)

This is the single most common source of broken plugins. Gallager speaks **three**
JSON dialects, and they do **not** all use the same key casing:

| Channel | Direction | Casing | Example keys |
|---|---|---|---|
| `plugin.json` manifest | on disk | **snake_case** | `schema_version`, `display_name`, `short_name`, `process_names` |
| Ingress **socket** frame | your hook → app | **snake_case** | `plugin_id`, `context`, `payload` |
| Stdio **transport** RPC | app ↔ sidecar | **camelCase** | `pluginID`, `sessionID`, `tmuxPane`, `pluginRoot` |

Why: the stdio transport serializes Swift structs with a plain encoder (no key
transformation), so the wire keys are the Swift property names verbatim
(`pluginID`, not `plugin_id`). The manifest and the socket frame are hand-coded in
snake_case. **If you copy a `plugin_id` key into a `translate_event` response, the
app silently drops the field.** When in doubt, the JSON your sidecar reads and
writes over stdin/stdout is camelCase.

---

## 2. Plugin layout & manifest schema

A plugin is a directory containing a `plugin.json` and an executable:

```
~/.gallager/plugins/my-agent/
├── plugin.json        # manifest (snake_case)
├── bin/
│   └── sidecar        # executable, chmod +x
└── assets/
    └── icon.png       # optional
```

### Manifest keys (snake_case)

| Key | Type | Required | Notes |
|-----|------|----------|-------|
| `schema_version` | int | no (default 1) | Must be `1` |
| `id` | string | **yes** | Path component — see ID rules |
| `display_name` | string | **yes** | Shown in Settings → Agents |
| `short_name` | string | **yes** | Pane badge label |
| `version` | string | no (default `"0.0.0"`) | Semver |
| `process_names` | [string] | no (default `[]`) | Process base-names for pane auto-detection |
| `runtime` | string | **yes** | Must be `"sidecar"` |
| `sidecar.executable` | string | **yes** | Path to binary under the plugin root (e.g. `"bin/sidecar"`) |
| `sidecar.args` | [string] | no (default `[]`) | Extra argv passed to the executable |
| `ui.icon` | string | no | Relative path to an icon asset |
| `ui.color` | string | no | Accent hex, e.g. `"#4A90E2"` (default `"#888888"`) |
| `publisher` | string | no | Human-readable publisher name |
| `manifest_url` | string | no | HTTPS URL of this manifest (remote install) |
| `bundle_url` | string | no | HTTPS URL of the zip bundle (remote install) |
| `bundle_sha256` | string | no | Lowercase hex SHA-256 of the bundle (remote install) |
| `capabilities.rich_pane_detection` | bool | no (default false) | Opt in to the `detect_pane` RPC |
| `capabilities.modal_prompts` | bool | no (default false) | Opt in to `prompt_user` / `deliver_response` |

### ID rules

`id` is a filesystem path component and must:
- match `^[a-z0-9][a-z0-9._-]*$` (lowercase letters, digits, `.`, `_`, `-`; first char alphanumeric),
- not contain `..`,
- be ≤ 128 chars,
- **exactly equal the directory name** under `~/.gallager/plugins/`.

---

## 3. Stdio JSON-RPC transport

### Framing (LSP-style Content-Length)

Every message, both directions, is:

```
Content-Length: <byte-count-of-body>\r\n
\r\n
<JSON body>
```

ASCII header, terminated by `\r\n\r\n`; `Content-Length` counts the body bytes
only. Gallager caps the header at 16 KiB and the body at 32 MiB. (This framing is
ONLY for stdio — the ingress socket uses a different format, see §8.)

### Envelope

| Field | Type | Present on |
|-------|------|------------|
| `id` | string | requests and their responses |
| `method` | string | requests and notifications |
| `params` | any JSON | requests and notifications |
| `result` | any JSON | successful responses |
| `error` | `{code, message}` | error responses |

- **Request** = `id` + `method`. Expects a response.
- **Notification** = `method`, no `id`. No response.
- **Response** = `id`, no `method`. **Must echo the request's exact `id`** — a
  response with an unknown `id` is silently discarded.

Error response:
```json
{ "id": "abc-123", "error": { "code": "method_not_found", "message": "Unknown method: foo" } }
```

Respond to **every** request you receive. For methods you don't implement, reply
with a `method_not_found` error (don't leave the request hanging — the app's RPC
has a per-call timeout, but a silent drop wastes it).

---

## 4. App → Sidecar requests

All are **requests** — the app waits for a response. `params` keys are camelCase.

| Method | `params` | Respond with |
|--------|----------|--------------|
| `initialize` | `PluginEnvWire` (below) | `{}` (any value). Sent once at startup AND after every crash-restart. Respond before doing anything else. |
| `translate_event` | `IngressFrameWire`: `{pluginID, context, payload}` | A `PluginEvent` (§6), or `null` to ignore. **The core method.** |
| `command_for_launch` | `{projectPath}` | `{command, args, env}` or `null` |
| `install` | `{configRoot: string\|null}` | `InstallResult`: `{"installed":{"message":"…"}}` or `{"alreadyInstalled":{}}` |
| `uninstall` | `{configRoot: string\|null}` | `{}` |
| `install_status` | `{configRoot: string\|null}` | `PluginInstallStatus`: `{"installed":{"version":"…"\|null}}` / `{"notInstalled":{}}` / `{"agentUnavailable":{}}` |
| `apply_settings` | `{settings: <json>}` | `SettingsResult`: `{"applied":{}}` or `{"error":{"field":null,"message":"…"}}` |
| `refresh_projects` | `null` | `{}` (then push `set_projects`, §5) |
| `deliver_response` | `{sessionID, requestID, response}` | `{}` (only with `modal_prompts`) |
| `shutdown` | `null` | `{}`, then flush and exit. SIGTERM follows in 5s, SIGKILL in 10s. |
| `detect_pane` | `SidecarPaneInfo`: `{paneID, processNames, command, cwd}` | `SidecarPaneMatch`: `{matches, projectPath, sessionID}` (only with `rich_pane_detection`) |

### `PluginEnvWire` (params for `initialize`)

```json
{
  "pluginRoot": "/Users/you/.gallager/plugins/my-agent",
  "stateDir": "/Users/you/.gallager/state/plugins/my-agent",
  "appVersion": "2.4.0",
  "settings": {},
  "marketplaceSource": "/path/to/marketplace/assets",
  "otlpReceiverEndpoint": "http://127.0.0.1:4318"
}
```

`otlpReceiverEndpoint` is `null` when no OTLP receiver is running. `settings` is
your plugin's current settings object (`{}` when empty). Treat every `initialize`
as a clean-slate boot — it is re-sent after a crash-restart.

---

## 5. Sidecar → App messages

### Notifications (you send, no response expected)

| Method | `params` | Effect |
|--------|----------|--------|
| `emit_event` | a `PluginEvent` (§6) | Push a state change outside of a `translate_event` reply |
| `set_projects` | `{projects: [AgentProject]}` | Replace your plugin's project list in the sidebar |
| `send_text` | `{sessionID, text}` | Type text into the session's focused pane |
| `send_keys` | `{sessionID, keys: [TmuxKey]}` | Send key presses into the pane |
| `log` | `{level, message}` | Structured log (`level` ∈ `debug`/`info`/`warn`/`error`); shows in Settings → View Logs |
| `prompt_user` | `{title, message?}` | Ask the app to show a modal (only with `modal_prompts`; answer arrives via `deliver_response`) |

`AgentProject` = `{name, path, pluginID, configDir?, lastUsed?}`. Omit `lastUsed`
unless you encode it as the app expects — leaving it out is safe.

### Requests (you send, app responds)

| Method | `params` | Returns |
|--------|----------|---------|
| `agent_panes` | `null` | `[string]` — tmux pane IDs Gallager believes belong to your agent |

When you send a request, generate a unique `id`, then watch the inbound stream for
a message whose `id` matches and read its `result`.

---

## 6. PluginEvent & AgentState (the heart)

`translate_event` (and `emit_event`) deliver a **PluginEvent** — the single
carrier for everything your plugin wants to change about a session. camelCase keys:

```json
{
  "pluginID": "my-agent",
  "sessionID": "abc-123",
  "state": { "doneWorking": { "summary": "Fixed the bug." } },
  "notification": { "title": "my-agent", "body": "Done." },
  "tmuxPane": "%4",
  "projectPath": "/Users/you/code/proj",
  "permissionMode": "default"
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `pluginID` | yes | Your plugin id (echo `params.pluginID`) |
| `sessionID` | yes | Stable id for this agent session. Derive from the payload; fall back to `tmuxPane` |
| `state` | no | New `AgentState` (below). `null`/omitted = "no opinion, leave unchanged" |
| `notification` | no | `{title, body}` — fires a Mac notification + iOS push |
| `tmuxPane` | no | Bootstraps the session↔pane mapping. Comes from `context.TMUX_PANE` |
| `projectPath` | no | Lets the sidebar show the project name immediately |
| `permissionMode` | no | `default`/`plan`/`acceptEdits`/`bypassPermissions`, if your agent reports it |

### AgentState encodings (single-key tagged object)

| State | JSON | Attention badge? |
|-------|------|------------------|
| Working | `{"working": {}}` | no |
| Idle / handled | `{"idle": {}}` | no |
| Finished a turn | `{"doneWorking": {"summary": "…" \| null}}` | **yes** |

Richer agents can also produce blocked-on-input states —
`{"awaitingPermission": {…}}`, `{"awaitingPlanApproval": {…}}`,
`{"awaitingReplies": {…}}` — which open a response form in the viewer and route the
answer back through `deliver_response`. These require structured request payloads;
start with `working`/`idle`/`doneWorking` and add the awaiting cases only once the
basic round-trip works.

---

## 7. Spawn environment

Gallager spawns your executable with the parent environment plus five variables.
Its working directory is set to `GALLAGER_PLUGIN_ROOT`.

| Variable | Example | Meaning |
|----------|---------|---------|
| `GALLAGER_PLUGIN_ROOT` | `~/.gallager/plugins/my-agent` | Plugin bundle dir (read-only assets) |
| `GALLAGER_STATE_DIR` | `~/.gallager/state/plugins/my-agent` | Writable scratch/state dir |
| `GALLAGER_APP_VERSION` | `2.4.0` | Host app version |
| `GALLAGER_INGRESS_SOCK` | `~/.gallager/state/ingress.sock` | Hook ingress socket path (§8) |
| `GALLAGER_PLUGIN_ID` | `my-agent` | Your manifest `id` |

---

## 8. Hook ingress channel

If your agent fires hook scripts, they forward events to Gallager through the
ingress socket — a **different** channel from the stdio transport.

### Frame format: 4-byte big-endian length prefix (NOT Content-Length)

```
[UInt32 big-endian byte count][JSON body bytes]
```

Body (snake_case):
```json
{
  "plugin_id": "my-agent",
  "context": { "TMUX_PANE": "%4", "CLAUDE_PROJECT_DIR": "/path" },
  "payload": { ... raw hook event ... }
}
```

- `plugin_id` must equal `GALLAGER_PLUGIN_ID` — it routes the frame to your sidecar.
- `context.TMUX_PANE` must be present (pane routing). Add any other env keys your
  `translate_event` reads.
- `payload` is your agent's raw hook event; it arrives at `translate_event` as the
  already-parsed `params.payload`.

Your sidecar's `install` should drop a hook bridge into the agent's config and
register it. See the bundled `assets/template/hook.py` for a working bridge. For a
shell bridge with `nc`: macOS/BSD `nc -U <path>`, Linux GNU netcat `nc --unixsock <path>`.

---

## 9. Lifecycle & crash policy

**Startup:** spawn → `initialize` request → you respond → ready.

**Supervised restart:** on unexpected exit, Gallager counts crashes in a rolling
60-second window and restarts after backoff (1 s, 2 s, 4 s). **On the 4th crash in
60 s the plugin is auto-disabled** (last 50 stderr lines kept for the banner).
After any restart Gallager re-sends `initialize` — be ready for it anytime.

**Shutdown:** `shutdown` request → you exit. SIGTERM after 5 s, SIGKILL after 10 s.

**stderr** is captured to `~/.gallager/state/plugins/<id>/logs/stderr.log` (rotated
at 5 MB). Structured `log` notifications go to a separate `sidecar.log`. Never
write non-RPC bytes to **stdout** — it corrupts the frame stream.

---

## 10. Distribution

### Folder-drop (simplest, great for development)

Copy the plugin directory to `~/.gallager/plugins/<id>/`. Gallager discovers it on
next launch. Requires: dir name == sanitized `id`; `plugin.json` decodes with
`runtime == "sidecar"`; the declared executable exists and is `chmod +x`.

### Remote install (for shipping to others)

Host `plugin.json` at an HTTPS URL with `bundle_url`, `bundle_sha256`,
`manifest_url`. The bundle is a zip whose root holds `plugin.json` + the executable.
Users install via Settings → "Add Plugin from URL…" or
`gallager plugin install https://example.com/plugin.json`.

Gallager enforces: https-only fetch → schema/id validation → **trust prompt** →
stream download (≤50 MiB) → SHA-256 verify → zip-slip-hardened unpack → tree
validation (executable present + executable bit) → atomic commit.

`gallager plugin update <id>` re-runs the flow from the stored `manifest_url`.
`gallager plugin remove <id>` calls your `uninstall`, disables, and deletes the dir.

---

## 11. Security model

Honest scope: **trusted-on-install, hash-pinned, runs with your permissions** — not
"safe to run untrusted code."

Provided: https-only transport, SHA-256 **integrity** pin (not authenticity), an
explicit trust prompt, zip-slip hardening. **Not** provided: no code signing or
publisher-identity verification (the `signature` field is reserved/ignored), no OS
sandbox (the sidecar runs as the user with full permissions), no marketplace
vetting. Do not run plugins from untrusted sources.

---

## 12. Known limitations

- `rich_pane_detection`: the `detect_pane` types exist and the capability flag is
  read, but the pane-detection call-site wiring is a follow-on. Declare it now;
  fall back to `process_names`. A `method_not_found` reply degrades gracefully.
- `modal_prompts`: `prompt_user`/`deliver_response` types exist behind the flag,
  but the modal UI is a follow-on.
- Crash-loop banner UI is a follow-on (the auto-disable still happens).
- OTLP: only `claude_code.*` and `codex.*` event namespaces are parsed today;
  a third-party namespace is silently dropped.
