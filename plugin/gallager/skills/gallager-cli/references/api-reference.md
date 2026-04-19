# Gallager CLI — Full API Reference

Every `gallager` subcommand wraps a JSON-RPC method sent over a Unix socket. This reference lists the method name, parameters, and response for each command, plus the wire protocol for callers that want to talk to the socket directly.

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
| `system.*` | Utility / introspection |
