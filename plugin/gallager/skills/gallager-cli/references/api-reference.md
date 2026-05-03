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

### `session.create` — `gallager new-session [--name] [--path] [--title] [--color] [--if-missing]`
- Params: `{ "name"?: string, "path"?: string, "title"?: string, "color"?: string, "if_missing"?: bool }`
- Result: `{ "id", "name", "windowCount", "isAttached", "created" }`
- When `if_missing` is true and a session with `name` already exists, the
  existing session info is returned with `created: false` instead of
  auto-suffixing the name. Otherwise `created: true`. Requires `name` when
  `if_missing` is set.
- `title` (when present) sets the sidebar `@gallager-description` for the
  resulting session — handy for one-shot scripts that don't want a follow-up
  `session.set_title` call.
- `color` (when present) sets the sidebar dot via `@gallager-color`. Accepts
  the same names as `session.set_color` (`red`, `orange`, `yellow`, `green`,
  `blue`, `purple`, `pink`, `gray`, plus the `violet`/`magenta`/`grey`
  aliases). Unknown names return `invalid_params`.

### `session.set_title` — `gallager set-title <text> [--session|--window|--pane]`
Writes the sidebar title (`@gallager-description` tmux user option). Window
scope wins when `window_id` is supplied; otherwise the title is applied at
session scope. Pass `title: ""` (or omit it) to clear.
- Params: `{ "title"?: string, "session_id"?: string, "window_id"?: string, "pane_id"?: string }`
- Result: `{ "scope": "session" | "window" }`
- Errors: `not_found` when the named session/window doesn't exist or no
  target can be resolved (e.g. invoked outside an attached session with no
  targeting flags). Detached windows are reachable via `<session>:<index>`.

### `session.set_color` — `gallager set-color <color> [--session|--window|--pane]`
Writes the sidebar dot color (`@gallager-color` tmux user option). Targeting
mirrors `session.set_title` — window scope wins when `window_id` is
supplied; otherwise the color applies at session scope. Pass `color: ""`
(or `none` from the CLI) to clear.
- Params: `{ "color": string, "session_id"?: string, "window_id"?: string, "pane_id"?: string }`
- Result: `{ "scope": "session" | "window" }`
- Errors: `invalid_params` for an unrecognised color name; `not_found` when
  the target doesn't resolve (same rules as `session.set_title`). Valid
  colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`,
  `gray` (aliases: `violet`/`magenta`/`grey`).

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
- The CLI fills `pane_id` from `$TMUX_PANE` when neither `--pane` nor
  `--session` is given, so the calling pane is targeted by default. With both
  parameters absent and no `$TMUX_PANE` (e.g. when invoked from outside tmux),
  the server falls back to the globally active pane. A Claude hook event whose
  `isWorking` is non-nil or that would trigger a notification clears the
  override for the same pane, so live sessions revert to hook-driven state on
  their own.

## Windows

### `window.list` — `gallager list-windows [--session]`
- Params: `{ "session_id"?: string, "pane_id"?: string }`
- Result: `{ "windows": [{ "id", "index", "name", "paneCount", "isActive", "sessionId" }, …] }`
- When `session_id` is omitted but `pane_id` is provided, the server resolves
  the pane to its session and filters accordingly. The CLI sends `pane_id`
  from `$TMUX_PANE` automatically when neither `--session` nor `--pane` is
  passed, so the listing defaults to the calling pane's session.

### `window.create` — `gallager new-window [--session] [--path] [--title]`
- Params: `{ "session_id"?: string, "path"?: string, "pane_id"?: string, "title"?: string }`
- Result: `{ "id", "index", "name", "paneCount", "isActive", "sessionId" }`
- When `session_id` is omitted but `pane_id` is provided, the new window is
  created in the pane's session. The CLI sends `pane_id` from `$TMUX_PANE`
  automatically when neither `--session` nor `--pane` is passed, so the new
  window lands in the calling pane's session.
- `title` (when present) sets the sidebar `@gallager-description` for the
  new window at creation time — equivalent to a follow-up
  `session.set_title --window <id>`.

### `window.select` — `gallager select-window <id>`
- Params: `{ "window_id": string }`
- Result: `{}`

### `window.close` — `gallager close-window <id>`
- Params: `{ "window_id": string }`
- Result: `{}`

## Panes

### `pane.list` — `gallager list-panes [--window]`
- Params: `{ "window_id"?: string, "pane_id"?: string }`
- When `window_id` is omitted but `pane_id` is provided, the server resolves
  the pane to its window and filters accordingly. The CLI sends `pane_id`
  from `$TMUX_PANE` automatically when neither `--window` nor `--pane` is
  passed, so the listing defaults to the calling pane's window.
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
- The CLI fills `pane_id` from `$TMUX_PANE` when no targeting flag is given,
  so the split happens on the calling pane.

### `pane.select` — `gallager select-pane <id>`
- Params: `{ "pane_id": string }`
- Result: `{}`

### `pane.capture` — `gallager capture-pane [--pane] [--scrollback]`
Returns the visible buffer of a pane as plain text — the same content as
`tmux capture-pane -p`. With `--scrollback` (`-S -`), the entire history is
included. Useful for grepping pane output without leaving the calling shell.
- Params: `{ "pane_id"?: string, "scrollback"?: bool }`
- Result: `{ "text": string }`
- The CLI fills `pane_id` from `$TMUX_PANE` when no targeting flag is given,
  so the capture defaults to the calling pane.

## Input

### `input.send_text` — `gallager send <text> [--pane] [--enter]`
Sends text verbatim. Pass `--enter` (or `enter: true`) to append a real
Enter keypress after the text — equivalent to following the call with
`input.send_key { key: "enter" }`. Without `--enter`, include `\n` in the
text yourself if you need a newline.
- Params: `{ "text": string, "pane_id"?: string, "enter"?: bool }`
- Result: `{}`
- The CLI fills `pane_id` from `$TMUX_PANE` when no targeting flag is given,
  so input goes to the calling pane.

### `input.send_key` — `gallager send-key <key> [--pane]`
Named keys: `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `space`.
- Params: `{ "key": string, "pane_id"?: string }`
- Result: `{}`
- The CLI fills `pane_id` from `$TMUX_PANE` when no targeting flag is given,
  so input goes to the calling pane.

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

### `system.ping` — `gallager ping` / `gallager wait-ready`
- Params: _(none)_
- Result: `{ "pong": true }`
- `wait-ready --timeout <seconds> --interval <seconds>` (CLI-only convenience)
  retries `system.ping` until success or the timeout elapses, exiting
  non-zero on timeout. Use it as a gate at the top of scripts that auto-launch
  the app instead of sleeping for a fixed duration. Defaults: 30s timeout,
  0.5s interval.

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
