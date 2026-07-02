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
4a. [Answering forms — request & response shapes](#4a-answering-forms--request--response-shapes)
5. [Sidecar → App messages](#5-sidecar--app-messages)
5a. [TmuxKey encoding (for send_keys)](#5a-tmuxkey-encoding-for-send_keys)
6. [PluginEvent & AgentState (the heart)](#6-pluginevent--agentstate-the-heart)
6a. [AppAction (the appActions array)](#6a-appaction-the-appactions-array)
7. [Spawn environment](#7-spawn-environment)
8. [Hook ingress channel](#8-hook-ingress-channel)
9. [Lifecycle & crash policy](#9-lifecycle--crash-policy)
10. [Distribution](#10-distribution)
11. [Security model](#11-security-model)
11a. [Telemetry — the OTLP meter](#11a-telemetry--the-otlp-meter)
12. [Known limitations](#12-known-limitations)
13. [Settings (generic sidecar settings)](#13-settings-generic-sidecar-settings)

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
| `sidecar.default_config_root` | string | no | The agent's default config location, shown as the non-removable root row in Settings → Agents (e.g. `"~/.config/my-agent"`). Purely presentational — when absent the UI falls back to `~`. `install` still receives `configRoot: null` for this default row (see §13). |
| `ui.icon` | string | no | Relative path to an icon asset |
| `ui.color` | string | no | Accent hex, e.g. `"#4A90E2"` (default `"#888888"`) |
| `publisher` | string | no | Human-readable publisher name |
| `manifest_url` | string | no | HTTPS URL of this manifest (remote install) |
| `bundle_url` | string | no | HTTPS URL of the zip bundle (remote install) |
| `bundle_sha256` | string | no | Lowercase hex SHA-256 of the bundle (remote install) |
| `capabilities.rich_pane_detection` | bool | no (default false) | Opt in to the `detect_pane` RPC |
| `capabilities.modal_prompts` | bool | no (default false) | Opt in to `prompt_user` / `deliver_response` |
| `otlp.namespace` | string | no | OTLP event-name namespace, no trailing dot (e.g. `"my-agent"`). Declaring it routes `<namespace>.<token_event>` log records into the per-session token/cost/latency meter (§11a). `claude_code` / `codex` cannot be claimed. |
| `otlp.token_event` | string | no (default `"api_request"`) | The namespace-stripped event name carrying the token/latency/model attributes (§11a) |

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
  "otlpReceiverEndpoint": "http://127.0.0.1:24318"
}
```

`otlpReceiverEndpoint` is `null` when no OTLP receiver is running; the port is
whatever the receiver actually bound this launch — use the value verbatim (§11a).
`settings` is your plugin's current settings object (`{}` when empty). Treat every
`initialize` as a clean-slate boot — it is re-sent after a crash-restart.

---

## 4a. Answering forms — request & response shapes

When you put the session into an `awaitingPermission` / `awaitingReplies` /
`awaitingPlanApproval` state (§6), you embed a **request** describing the form. When
the user answers, the app calls `deliver_response` with `{sessionID, requestID,
response}` — `requestID` is the exact value you sent in the state, and `response` is
an `AgentResponse` (a single-key tagged object). **No capability required.**

You then act on the answer however your agent allows — call your agent's API, or (if
the agent's only surface is its TUI) inject keystrokes with `send_keys` (§5).
Respond `{}` to the `deliver_response` request promptly; do the side-effect first or
fire-and-forget.

### The request you embed

**PermissionRequest** (the `_0` of `awaitingPermission`):
```json
{
  "title": "Run shell command",
  "description": "rm -rf build/",
  "isAutoApprovable": false,
  "suggestions": [ { "id": "always", "label": "Allow always for this session", "detail": null } ],
  "allowsCustomInstructions": true
}
```
`title`/`description`/`isAutoApprovable`/`suggestions`/`allowsCustomInstructions` are
all required (`suggestions[].detail` is the only optional). `isAutoApprovable: true`
lets the app auto-approve in yolo mode without showing a form.

**AskUserQuestionRequest** (the `_0` of `awaitingReplies`):
```json
{
  "questions": [
    {
      "id": "q0",
      "question": "Which approach?",
      "header": "Approach",
      "options": [
        { "id": "q0-o0", "label": "Rewrite", "description": "…", "preview": null }
      ],
      "multiSelect": false,
      "allowsFreeText": true
    }
  ]
}
```
`preview` is optional; everything else required. Use stable option ids like
`"q<i>-o<j>"` so you can map the answer back.

(`ApprovePlanRequest` is analogous; if your agent has no plan-approval step, leave
it unused — start with permission/questions.)

### The `response` you receive

`AgentResponse` cases (single-key tagged object):

| Case | JSON | Notes |
|------|------|-------|
| `permission` | `{"permission": {"decision": <PermissionDecision>, "appliedSuggestionID": "always"\|null}}` | `appliedSuggestionID` is the `suggestions[].id` the user tapped, if any |
| `askUserQuestion` | `{"askUserQuestion": {"answers": [{"questionID": "q0", "selectedOptionIDs": ["q0-o1"], "freeText": null}]}}` | one entry per question; `freeText` set when the user typed "Other" |
| `prompt` | `{"prompt": {"text": "…"}}` | free-text prompt submission |
| `replyAfterStop` | `{"replyAfterStop": {"text": "…"}}` | empty text = "interrupt, send nothing" |
| `approvePlan` | `{"approvePlan": {"decision": <PlanDecision>, "editedPlan": "…"\|null}}` | |

**PermissionDecision** is itself tagged: `"allow"`, `"deny"`, or
`{"denyWithFeedback": "use tabs instead"}` (deny + free-text feedback). A plain
`"allow"`/`"deny"` are no-payload cases → bare strings.

---

## 5. Sidecar → App messages

### Notifications (you send, no response expected)

| Method | `params` | Effect |
|--------|----------|--------|
| `emit_event` | a `PluginEvent` (§6) | Push a state change outside of a `translate_event` reply |
| `set_projects` | `{projects: [AgentProject]}` | Replace your plugin's project list in the sidebar |
| `send_text` | `{sessionID, text}` | Type text into the session's focused pane |
| `send_keys` | `{sessionID, keys: [TmuxKey]}` | Send key presses into the pane (see §5a for the `TmuxKey` shapes — `.text` is **not** a bare string) |
| `log` | `{level, message}` | Structured log (`level` ∈ `debug`/`info`/`warn`/`error`); shows in Settings → View Logs |
| `prompt_user` | `{title, message?}` | Ask the app to show a modal (only with `modal_prompts`; answer arrives via `deliver_response`) |

`AgentProject` = `{name, path, pluginID, configDir?, lastUsed?}` (`id` is computed
host-side, not encoded). `lastUsed` is a `Date` decoded by a default `JSONDecoder`
(`.deferredToDate`), so it must be **seconds since the 2001 reference date**, i.e.
`unix_seconds - 978307200`. A wrong format (e.g. raw unix millis) throws and the
host drops the *entire* project list. When in doubt, omit it (recency sort just
falls back) — leaving it out is safe.

### Requests (you send, app responds)

| Method | `params` | Returns |
|--------|----------|---------|
| `agent_panes` | `null` | `[string]` — tmux pane IDs Gallager believes belong to your agent |

When you send a request, generate a unique `id`, then watch the inbound stream for
a message whose `id` matches and read its `result`.

---

## 5a. TmuxKey encoding (for `send_keys`)

`keys` is an array of `TmuxKey`, each a single-key tagged object (same auto-derived
`Codable` rules as §6 — **a `_0`-wrapped associated value, NOT a bare string**). The
whole array is decoded with `try?`: if even one element is malformed, **every**
keystroke is silently dropped and nothing is sent.

| Key | JSON |
|-----|------|
| Literal text | `{"text": {"_0": "hello"}}` — ⚠️ NOT `{"text": "hello"}` (that fails to decode) |
| Enter / Shift-Enter | `{"enter": {}}` / `{"shiftEnter": {}}` |
| Escape / Tab / Backtab | `{"escape": {}}` / `{"tab": {}}` / `{"backtab": {}}` |
| Space / Backspace / Delete | `{"space": {}}` / `{"backspace": {}}` / `{"delete": {}}` |
| Arrows | `{"up": {}}` / `{"down": {}}` / `{"left": {}}` / `{"right": {}}` |
| Home / End / PageUp / PageDown | `{"home": {}}` / `{"end": {}}` / `{"pageUp": {}}` / `{"pageDown": {}}` |
| Ctrl / Alt / Ctrl+Alt + char | `{"ctrl": {"_0": "c"}}` / `{"alt": {"_0": "b"}}` / `{"ctrlAlt": {"_0": "x"}}` |
| Delay (ms, not a real key) | `{"delay": {"_0": 100}}` |

Example `send_keys` to type "yes" and submit:
```json
{ "method": "send_keys",
  "params": { "sessionID": "%4", "keys": [ {"text": {"_0": "yes"}}, {"enter": {}} ] } }
```

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
  "appActions": [],
  "tmuxPane": "%4",
  "projectPath": "/Users/you/code/proj",
  "permissionMode": "default"
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `pluginID` | yes | Your plugin id (echo `params.pluginID`) |
| `sessionID` | yes | Stable id for this agent session. Derive from the payload; fall back to `tmuxPane` |
| `appActions` | **yes (always send it)** | Array of `AppAction` (§6a). Empty `[]` for almost every event. **See the warning below — omitting this key silently drops the whole event.** |
| `state` | no | New `AgentState` (below). `null`/omitted = "no opinion, leave unchanged" |
| `notification` | no | `{title, body}` — fires a Mac notification + iOS push |
| `tmuxPane` | no | Bootstraps the session↔pane mapping. Comes from `context.TMUX_PANE` |
| `projectPath` | no | Lets the sidebar show the project name immediately |
| `permissionMode` | no | `default`/`plan`/`acceptEdits`/`bypassPermissions`, if your agent reports it |

> ⚠️ **`appActions` is non-Optional and has NO decode default.** In the host's
> `PluginEvent` it is `[AppAction]` (not `[AppAction]?`), decoded with `decode`
> (not `decodeIfPresent`). A `translate_event` reply or `emit_event` payload that
> omits the `appActions` key **fails to decode and the host silently drops the
> entire event** — the session state never changes and there is no error anywhere
> visible to you. This is the #2 cause (after casing) of "the plugin loads but
> nothing happens." Always include `"appActions": []` (or a populated list). The
> memberwise `= []` default you may see in the Swift source applies only to direct
> Swift construction, **not** to JSON decoding.

### Tagged-enum encoding rule (applies to `state`, `appActions`, and responses)

Every Swift enum below serializes the same way (auto-synthesized `Codable`, no key
strategy):

- **No associated values** → a single-key object with an empty object value:
  `.working` → `{"working": {}}`, `.idle` → `{"idle": {}}`. (NOT the bare string
  `"working"` — that fails to decode.)
- **Labeled associated values** → keys are the labels:
  `.doneWorking(summary:)` → `{"doneWorking": {"summary": "…"}}`.
- **One *unlabeled* associated value** → it becomes the key `"_0"`:
  `.awaitingPermission(req, requestID:)` → `{"awaitingPermission": {"_0": <req>, "requestID": "…"}}`.
- **Mixed** → unlabeled positions are `"_0"`, `"_1"`, …; labeled ones use their label.

Internalize this — it governs `AgentState`, `AppAction`, `AgentResponse`,
`PermissionDecision`, **and `TmuxKey`** (§5a). Getting the `"_0"` wrapping wrong is
the single most common wire bug after the casing trap.

### AgentState encodings (single-key tagged object)

| State | JSON | Attention badge? |
|-------|------|------------------|
| Working | `{"working": {}}` | no |
| Idle / handled | `{"idle": {}}` | no |
| Finished a turn | `{"doneWorking": {"summary": "…" \| null}}` | **yes** |

Richer agents can also produce **blocked-on-input** states. These open a response
form in the Mac app / iOS viewer and route the answer back through
`deliver_response` (§4a). **They do NOT require any capability** — `modal_prompts`
gates only the host-originated `prompt_user` modal, not these agent-originated
forms; you can use `awaitingPermission`/`awaitingReplies` with no capabilities
declared. Each wraps a structured request (its first, unlabeled associated value →
`"_0"`) plus a `requestID` you echo back when the answer arrives:

| State | JSON | Request type (`_0`) |
|-------|------|----------------------|
| Blocked on a tool permission | `{"awaitingPermission": {"_0": <PermissionRequest>, "requestID": "…"}}` | `PermissionRequest` |
| Blocked on questions | `{"awaitingReplies": {"_0": <AskUserQuestionRequest>, "requestID": "…"}}` | `AskUserQuestionRequest` |
| Blocked on plan approval | `{"awaitingPlanApproval": {"_0": <ApprovePlanRequest>, "requestID": "…"}}` | `ApprovePlanRequest` |

Pick a `requestID` that is **stable per prompt** (e.g. `"<sessionID>:permission:<agent-prompt-id>"`)
so a re-sent event collapses to one form, and so a later `deliver_response` can map
it back to the right agent prompt. Start with `working`/`idle`/`doneWorking`; add
the awaiting cases once the basic round-trip works. The request/response shapes are
in §4a.

---

## 6a. AppAction (the `appActions` array)

`appActions` carries side-effects the host should perform that are *not* a session
state change. Each element is a single-key tagged object. **Almost every event
sends `[]`** — the one you will likely use is `sessionEnded`.

| Action | JSON | Effect |
|--------|------|--------|
| End the session | `{"sessionEnded": {"sessionID": "%4", "closePaneEligible": false}}` | Removes the sidebar row, resets the pane's session-scoped state. **`sessionID` here is the tmux PANE id** (the host keys session-end by pane), NOT your agent's session id — use `context.TMUX_PANE`. `closePaneEligible: true` closes the pane too; gate it on your `close_pane_on_session_end` setting (§13). |
| Suggest opening a file | `{"openFileSuggestion": {"sessionID": "…", "path": "/…", "displayName": "plan.md", "isPlan": false, "projectDir": "/…"\|null}}` | Surfaces an "open this file?" prompt. Niche — most plugins never emit it. |
| Clear file suggestions | `{"dismissFileSuggestions": {"sessionID": "…"}}` | Dismisses outstanding suggestions. |

**Session lifecycle pattern.** If your agent fires no event on launch or quit (and
the host's process scan only re-detects on pane add/remove, not when a process
starts/dies inside a live pane), emit two synthetic events of your own — one when
your bridge starts (→ `state: {"idle": {}}`, no appActions, so the session appears)
and one on graceful exit (→ `state: null`, `appActions: [{"sessionEnded": …}]`).
This mirrors Claude Code's `SessionStart`/`SessionEnd`. (A graceful-exit signal — a
shutdown finalizer in the agent's plugin, awaited so the frame flushes before the
process dies — covers `/exit` and Ctrl-C; a hard kill skips it and the session
lingers until the host next reconciles.)

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

Something running in your agent's process must forward events to Gallager through
the ingress socket — a **different** channel from the stdio transport. What that
"something" is depends on the agent:

- **Shell hooks** (Claude Code, Codex): the agent runs a script per event. Use the
  bundled `assets/template/hook.py` as the bridge; your `install` registers it.
- **Agent-native plugin / event bus** (for agents that have *removed* shell hooks):
  the agent loads a small plugin, written in its own plugin format, that subscribes
  to its event bus and forwards frames. The bridge bakes in the socket path + plugin
  id at install time (the agent process does not inherit Gallager's env).
- **No event surface at all:** the agent is only process-detected (`process_names`)
  and you may need little beyond `initialize`.

Either way the frame format is identical:

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

> ⚠️ Discovery checks `isDirectory`, which is **false for a symlink-to-directory**
> (Foundation reports the link itself). A dev install script must **copy** the
> plugin into `~/.gallager/plugins/<id>/`, not symlink it — and re-copy after edits,
> then relaunch.

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

## 11a. Telemetry — the OTLP meter

Optional: give your agent the same per-session token / cost / latency / model
meter Claude Code and Codex have. Two steps:

1. **Manifest**: declare your namespace (`otlp.namespace`, `otlp.token_event` —
   see the schema table in §2). Records in undeclared namespaces are silently
   dropped; the declaration applies while your plugin is enabled.
2. **Emit**: POST OTLP/JSON log records to `<otlpReceiverEndpoint>/v1/logs`
   (the endpoint arrives in the `initialize` env; `null` when no receiver is
   running — then skip telemetry). One record per completed model call, with
   Claude's exact `api_request` attribute keys, values **additive** per record
   (never cumulative totals):

```json
{ "resourceLogs": [{ "scopeLogs": [{ "logRecords": [{
  "eventName": "my-agent.api_request",
  "attributes": [
    { "key": "event.name",            "value": { "stringValue": "my-agent.api_request" } },
    { "key": "session.id",            "value": { "stringValue": "<your reported sessionID>" } },
    { "key": "input_tokens",          "value": { "intValue": 1234 } },
    { "key": "output_tokens",         "value": { "intValue": 567 } },
    { "key": "cache_read_tokens",     "value": { "intValue": 0 } },
    { "key": "cache_creation_tokens", "value": { "intValue": 0 } },
    { "key": "cost_usd",              "value": { "doubleValue": 0.0123 } },
    { "key": "duration_ms",           "value": { "intValue": 4200 } },
    { "key": "model",                 "value": { "stringValue": "some-model" } }
  ]
}] }] }] }
```

`session.id` must equal the session identity your sidecar reports in its
`PluginEvent`s (the pane id for a pane-keyed plugin) — that's the join key that
attaches the meter to the pane. Fold reasoning/thinking tokens into
`output_tokens` (Claude's convention). The agent process usually does not
inherit Gallager's env, so bake the endpoint into whatever emits (the opencode
plugin substitutes a token in its bridge at `install`, exactly like its ingress
socket path).

---

## 12. Known limitations

- `rich_pane_detection`: the `detect_pane` types exist and the capability flag is
  read, but the pane-detection call-site wiring is a follow-on. Declare it now;
  fall back to `process_names`. A `method_not_found` reply degrades gracefully.
- `modal_prompts`: gates only the **host-originated** `prompt_user` modal, whose UI
  is a follow-on. It does **not** gate the agent-originated form path —
  `awaitingPermission`/`awaitingReplies`/`awaitingPlanApproval` states +
  `deliver_response` work today with no capability declared (§4a, §6).
- Crash-loop banner UI is a follow-on (the auto-disable still happens).
- OTLP: a declared namespace (§11a) surfaces only the single `token_event` record
  shape. Claude's richer signals (tool-result counts, commit/PR milestones,
  permission-mode events) have no declared-namespace equivalent yet.

---

## 13. Settings (generic sidecar settings)

Every folder-dropped sidecar gets the same generic Settings → Agents panel for free
— no per-plugin UI. The settings object reaches you as `initialize.settings` and via
`apply_settings` (`{"settings": {...}}`), and is **snake_case** (it's hand-coded, like
the manifest). The standard keys (all optional, with these defaults):

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `command_path` | string | `""` | Launch-command override. Empty → use your own `command_for_launch` default. |
| `auto_run` | bool | `true` | When `false`, return `null` from `command_for_launch` (don't auto-start). |
| `log_level` | string | `"info"` | `debug`/`info`/`warn`/`error`. |
| `additional_config_folders` | [string] | `[]` | Extra per-project config roots (see `configRoot` below). |
| `close_pane_on_session_end` | bool | `false` | Fold into `sessionEnded`'s `closePaneEligible` (§6a). |

A typical sidecar honors these in `command_for_launch` (gate on `auto_run`, prefer
`command_path`) and in `install`/`install_status`/`uninstall`.

### `configRoot` (install scoping)

`install`/`uninstall`/`install_status` receive `{configRoot: string | null}`:

- `null` → the **default** row. Install your bridge into the agent's global config
  (the `sidecar.default_config_root` from the manifest is the label shown for it).
- a path → a **per-project** row the user added (one of `additional_config_folders`).
  Install the bridge into that project's local config so the agent loads it only
  there (e.g. `<root>/.my-agent/plugin/`).
