# Gallager CLI — Full API Reference

Every `gallager` subcommand wraps a JSON-RPC method sent over a Unix socket. This reference lists the method name, parameters, and response for each command, plus the wire protocol for callers that want to talk to the socket directly.

## Gallager is tmux underneath

Every session, window, and pane the API returns is a real tmux object on the user's tmux server. The IDs are identical to tmux's own identifiers:

| API field | tmux identifier |
|-----------|-----------------|
| `Session.id` / `Session.name` | tmux session name (use with `tmux … -t <name>`) |
| `Window.id` (e.g. `main:0`) | tmux `session:index` target |
| `Window.sessionId` | tmux session name |
| `Pane.id` (e.g. `%3`) | tmux pane ID — identical to `$TMUX_PANE` inside the pane |
| `Pane.windowId` | tmux `session:index` target |
| `Pane.command` / `Pane.cwd` | tmux `#{pane_current_command}` / `#{pane_current_path}` |

If the API does not expose an operation you need, call `tmux` directly against the same objects — Gallager observes tmux state continuously and the app will reflect the change without an explicit refresh. For example: `tmux rename-window`, `tmux resize-pane -x/-y`, `tmux capture-pane`, `tmux swap-pane`, `tmux join-pane`, `tmux select-layout`, and `tmux set-option` all work on Gallager-managed sessions.

Inside a Gallager-managed pane, `$TMUX` is set by tmux itself, so bare `tmux …` talks to the correct server. From outside a managed pane — or when the user has configured a custom tmux socket — pass `tmux -S <socket>` to match the server Gallager drives.

## Wire protocol

Newline-delimited JSON-RPC over `AF_UNIX, SOCK_STREAM`. Each message is a single JSON object followed by `\n`. Connections are persistent — a single connection can carry multiple requests.

### Request
```json
{ "id": "unique-id", "method": "session.list", "params": {} }
```
- `id` — arbitrary correlation string, echoed in the response
- `method` — dot-separated `domain.action`
- `params` — method-specific object (may be `{}`)

### Success response
```json
{ "id": "unique-id", "ok": true, "result": { ... } }
```

### Error response
```json
{
  "id": "unique-id",
  "ok": false,
  "error": { "code": "not_found", "message": "Session 'foo' not found" }
}
```

### Error codes
| Code | Meaning |
|------|---------|
| `not_found` | Resource (session/window/pane) doesn't exist |
| `invalid_params` | Required parameter missing or invalid |
| `method_not_found` | Method name is unknown |
| `internal_error` | Unexpected app-side failure |

## Sessions

### `session.list` — `gallager list-sessions`
- Params: _(none)_
- Result: `{ "sessions": [{ "id", "name", "windowCount", "isAttached" }, …] }`

### `session.create` — `gallager new-session [--name] [--path]`
- Params: `{ "name"?: string, "path"?: string }`
- Result: `{ "id", "name", "windowCount", "isAttached" }`

### `session.select` — `gallager select-session <id>`
- Params: `{ "session_id": string }`
- Result: `{}`

### `session.current` — `gallager current-session`
- Params: _(none)_
- Result: `{ "id", "name", "windowCount", "isAttached" }`

### `session.close` — `gallager close-session <id>`
- Params: `{ "session_id": string }`
- Result: `{}`

### `session.set_state` — `gallager session-state <state>`
- Params: `{ "state": "working" | "idle" | "waiting" | "clear", "pane_id"?: string, "session_id"?: string }`
- Result: `{ "applied_to": int }` — number of panes whose override was updated.
- With both `pane_id` and `session_id` omitted, the active pane is targeted. A
  Claude hook event whose `isWorking` is non-nil or that would trigger a
  notification clears the override for the same pane, so live sessions revert to
  hook-driven state on their own.

## Windows

### `window.list` — `gallager list-windows [--session]`
- Params: `{ "session_id"?: string }`
- Result: `{ "windows": [{ "id", "index", "name", "paneCount", "isActive", "sessionId" }, …] }`

### `window.create` — `gallager new-window [--session] [--path]`
- Params: `{ "session_id"?: string, "path"?: string }`
- Result: `{ "id", "index", "name", "paneCount", "isActive", "sessionId" }`

### `window.select` — `gallager select-window <id>`
- Params: `{ "window_id": string }`
- Result: `{}`

### `window.close` — `gallager close-window <id>`
- Params: `{ "window_id": string }`
- Result: `{}`

## Panes

### `pane.list` — `gallager list-panes [--window]`
- Params: `{ "window_id"?: string }`
- Result:
```json
{
  "panes": [{
    "id": "%3", "index": 0, "isActive": true,
    "command": "claude", "cwd": "/Users/me/project",
    "width": 220, "height": 50,
    "windowId": "main:0", "hasClaudeSession": true
  }]
}
```

### `pane.split` — `gallager split-pane [direction] [--pane] [--path]`
- Params: `{ "direction"?: "left"|"right"|"up"|"down", "pane_id"?: string, "path"?: string }`
- Result: pane object (same shape as `pane.list`)

### `pane.select` — `gallager select-pane <id>`
- Params: `{ "pane_id": string }`
- Result: `{}`

## Input

### `input.send_text` — `gallager send <text> [--pane]`
Sends text verbatim — include `\n` in the text for Enter.
- Params: `{ "text": string, "pane_id"?: string }`
- Result: `{}`

### `input.send_key` — `gallager send-key <key> [--pane]`
Named keys: `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `space`.
- Params: `{ "key": string, "pane_id"?: string }`
- Result: `{}`

## Notifications

### `notification.create` — `gallager notify --title --body [--subtitle]`
If `$TMUX_PANE` is set, the CLI attaches `pane_id` so the notification can deep-link back to the originating pane.
- Params: `{ "title": string, "body": string, "subtitle"?: string, "pane_id"?: string }`
- Result: `{}`

## Editor

### `editor.open` — `gallager edit <file>`
Opens the file in Gallager's in-app prompt editor. **Blocks** until the user submits or cancels.
- Params: `{ "pane_id": string, "file_path": string }` (pane_id comes from `$TMUX_PANE`)
- Result: `{}` (returned when editing completes)

## Projects

### `project.list` — `gallager list-projects`
Returns the Claude projects discovered on the host (from `~/.claude.json` and any additional configured folders), sorted by most recently used.
- Params: _(none)_
- Result:
```json
{
  "projects": [
    { "id": "/Users/me/code/proj", "name": "proj", "path": "/Users/me/code/proj", "last_used": "2026-04-19T12:34:56.789Z" }
  ]
}
```
`last_used` is `null` when no session activity has been recorded yet.

### `project.start` — `gallager start-project <path> [-- <args…>]`
Creates a new tmux session whose working directory is the given project path and runs the configured `claude` command in it. Any extra positional args after `--` are appended verbatim to the claude command line.
- Params: `{ "path": string, "args"?: [string] }`
- Result: session info object — `{ "id", "name", "window_count", "is_attached" }`
- Errors: `not_found` if `path` does not exist or is not a directory.

## System / utility

### `system.ping` — `gallager ping`
- Params: _(none)_
- Result: `{ "pong": true }`

### `system.capabilities` — `gallager capabilities`
- Params: _(none)_
- Result: `{ "methods": ["session.list", "session.create", …] }`

### `system.identify` — `gallager identify`
Returns session/window/pane for the calling process (uses `$TMUX_PANE` for detection).
- Params: `{ "pane_id"?: string }`
- Result: `{ "session": {…}, "window": {…}, "pane": {…} }`

## Method naming convention

| Prefix | Domain |
|--------|--------|
| `session.*` | Session management |
| `window.*` | Window management |
| `pane.*` | Pane management |
| `input.*` | Text and key input |
| `notification.*` | Desktop notifications |
| `editor.*` | Prompt editor |
| `project.*` | Claude project discovery and session bootstrap |
| `system.*` | Utility / introspection |
