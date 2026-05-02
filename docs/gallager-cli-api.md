# Gallager CLI API Reference

`gallager` is a command-line interface for controlling the Gallager macOS app. It communicates with the app over a Unix domain socket using JSON-RPC, enabling programmatic control of sessions, windows, panes, input, and notifications from scripts or shell environments.

---

## Quick Start

```bash
# Check that Gallager is running
gallager ping

# List all tmux sessions
gallager list-sessions

# Create a new session and switch to it
gallager new-session --name work
gallager select-session work

# Send text to the active pane
gallager send "echo hello\n"

# Send a desktop notification from a script
gallager notify --title "Build done" --body "Tests passed"

# Open a file in the in-app prompt editor (blocks until submitted)
gallager edit /tmp/prompt.txt
```

---

## Configuration

### Socket Path Resolution

`gallager` connects to the app through a Unix domain socket. The path is resolved in this order:

1. `--socket <path>` flag (highest priority)
2. `$GALLAGER_SOCKET` environment variable
3. `$TMPDIR/gallager.sock` (fallback for manual use outside a managed session)

Inside Gallager-managed tmux sessions, `$GALLAGER_SOCKET` is set automatically. Scripts running in those sessions do not need any additional configuration.

### Output Format

By default, commands print human-readable output. Pass `--json` to receive raw JSON-RPC response objects, which is useful for scripting and piping into `jq`.

```bash
gallager list-sessions --json | jq '.result.sessions[].name'
```

---

## Commands

### Sessions

#### `list-sessions`

List all tmux sessions managed by Gallager.

```bash
gallager list-sessions
```

**JSON-RPC**
- Method: `session.list`
- Params: _(none)_
- Response:
```json
{
  "id": "1",
  "ok": true,
  "result": {
    "sessions": [
      { "id": "main", "name": "main", "windowCount": 3, "isAttached": true },
      { "id": "work", "name": "work", "windowCount": 1, "isAttached": false }
    ]
  }
}
```

---

#### `new-session`

Create a new tmux session.

```bash
gallager new-session
gallager new-session --name myproject
gallager new-session --name myproject --title "My project"
gallager new-session --name workers --if-missing
```

**Options**
- `--name <name>` — base name for the session (auto-deduplicated to `name-2`, `name-3` if needed unless `--if-missing` is set)
- `--path <dir>` — initial working directory (defaults to `$HOME`)
- `--title <text>` — custom sidebar title; persisted as a tmux user option
- `--if-missing` — when a session with `--name` already exists, return its info instead of creating a new one. The response includes `created: false` so scripts can decide whether to populate panes

**JSON-RPC**
- Method: `session.create`
- Params: `{ "name": "myproject", "path": "/Users/me", "title": "My project", "if_missing": true }` _(all optional)_
- Response:
```json
{
  "id": "2",
  "ok": true,
  "result": {
    "id": "myproject", "name": "myproject",
    "window_count": 1, "is_attached": false,
    "created": true
  }
}
```

---

#### `set-title <text>`

Set a custom title shown for a session or window in the sidebar. The title is persisted as a tmux user option (`@gallager-description`) so it survives app restarts. Pass an empty string to clear.

Targeting:
- `--session <id>` — applies at session scope (every window inherits it)
- `--window <id>` — applies at window scope (overrides the session value for that window). Detached windows are reachable as `<session>:<index>`
- `--pane <id>` — applies at the session containing that pane
- _(none)_ — defaults to the calling pane's session via `$TMUX_PANE`

```bash
gallager set-title --session workers "Workers"
gallager set-title --window workers:1 "Builds"
gallager set-title ""                # clear title for the calling session
```

**JSON-RPC**
- Method: `session.set_title`
- Params: `{ "title": "Workers", "session_id": "workers" }` _(at least one of `session_id`/`window_id`/`pane_id` should be set; otherwise the active session is used)_
- Response: `{ "scope": "session" | "window" }`
- Errors: `not_found` when the named session/window doesn't exist or no target can be resolved (e.g. invoked outside an attached session with no targeting flags).

---

#### `select-session <id>`

Switch the app to a session by ID.

```bash
gallager select-session work
```

**JSON-RPC**
- Method: `session.select`
- Params: `{ "session_id": "work" }`
- Response: `{ "ok": true }`

---

#### `current-session`

Show the currently active session.

```bash
gallager current-session
```

**JSON-RPC**
- Method: `session.current`
- Params: _(none)_
- Response:
```json
{
  "id": "3",
  "ok": true,
  "result": { "id": "main", "name": "main", "windowCount": 2, "isAttached": true }
}
```

---

#### `close-session <id>`

Close a session and all its windows.

```bash
gallager close-session work
```

**JSON-RPC**
- Method: `session.close`
- Params: `{ "session_id": "work" }`
- Response: `{ "ok": true }`

---

### Windows

#### `list-windows`

List windows in the current session, or a specific session with `--session`.

```bash
gallager list-windows
gallager list-windows --session work
```

**JSON-RPC**
- Method: `window.list`
- Params: `{ "session_id": "work" }` _(session_id is optional)_
- Response:
```json
{
  "id": "4",
  "ok": true,
  "result": {
    "windows": [
      { "id": "main:0", "index": 0, "name": "editor", "paneCount": 2, "isActive": true, "sessionId": "main" },
      { "id": "main:1", "index": 1, "name": "server", "paneCount": 1, "isActive": false, "sessionId": "main" }
    ]
  }
}
```

---

#### `new-window`

Create a new window in the current session, or a specific session with `--session`.

```bash
gallager new-window
gallager new-window --session work
gallager new-window --session work --title "Builds"
```

**Options**
- `--session <id>` — target session (defaults to the calling pane's session)
- `--path <dir>` — initial working directory (defaults to `$HOME`)
- `--title <text>` — custom sidebar title scoped to the new window only

**JSON-RPC**
- Method: `window.create`
- Params: `{ "session_id": "work", "path": "/tmp", "title": "Builds" }` _(all optional)_
- Response:
```json
{
  "id": "5",
  "ok": true,
  "result": { "id": "work:1", "index": 1, "name": "bash", "pane_count": 1, "is_active": false, "session_id": "work" }
}
```

---

#### `select-window <id>`

Switch to a window by ID.

```bash
gallager select-window main:1
```

**JSON-RPC**
- Method: `window.select`
- Params: `{ "window_id": "main:1" }`
- Response: `{ "ok": true }`

---

#### `close-window <id>`

Close a window and all its panes.

```bash
gallager close-window main:1
```

**JSON-RPC**
- Method: `window.close`
- Params: `{ "window_id": "main:1" }`
- Response: `{ "ok": true }`

---

### Panes

#### `list-panes`

List panes in the current window, or a specific window with `--window`.

```bash
gallager list-panes
gallager list-panes --window main:0
```

**JSON-RPC**
- Method: `pane.list`
- Params: `{ "window_id": "main:0" }` _(window_id is optional)_
- Response:
```json
{
  "id": "6",
  "ok": true,
  "result": {
    "panes": [
      {
        "id": "%3", "index": 0, "isActive": true,
        "command": "claude", "cwd": "/Users/me/project",
        "width": 220, "height": 50,
        "windowId": "main:0", "hasClaudeSession": true
      }
    ]
  }
}
```

---

#### `split-pane [direction]`

Split the current pane. Direction is `left`, `right`, `up`, or `down` (default: `right`). Use `--pane` to target a specific pane.

```bash
gallager split-pane
gallager split-pane down
gallager split-pane right --pane %3
```

**JSON-RPC**
- Method: `pane.split`
- Params: `{ "direction": "down", "pane_id": "%3" }` _(both optional)_
- Response:
```json
{
  "id": "7",
  "ok": true,
  "result": {
    "id": "%6", "index": 1, "isActive": false,
    "command": "bash", "cwd": "/Users/me/project",
    "width": 220, "height": 24,
    "windowId": "main:0", "hasClaudeSession": false
  }
}
```

---

#### `select-pane <id>`

Focus a pane by its tmux pane ID.

```bash
gallager select-pane %3
```

**JSON-RPC**
- Method: `pane.select`
- Params: `{ "pane_id": "%3" }`
- Response: `{ "ok": true }`

---

#### `capture-pane`

Print recent pane output as plain text. Surfaces `tmux capture-pane -p` for scripts that want to read pane content (grep a build log, assert on a test output, wait for a specific line). Defaults to the calling pane via `$TMUX_PANE` when `--pane` isn't given.

```bash
gallager capture-pane                       # visible region of the calling pane
gallager capture-pane --pane %3             # specific pane
gallager capture-pane --pane %3 --scrollback  # include the entire scrollback
```

**JSON-RPC**
- Method: `pane.capture`
- Params: `{ "pane_id": "%3", "scrollback": false }` _(both optional)_
- Response: `{ "content": "<captured text>" }`

---

### Input

#### `send <text>`

Send text to the active pane, or a specific pane with `--pane`. The text is sent literally — pass `--enter` to append a real Enter keypress after the text (avoids shell-specific `$'cmd\n'` quoting tricks).

```bash
gallager send "ls -la" --enter
gallager send "hello" --pane %5
gallager send "make test" --enter --pane %3
```

**Options**
- `--enter` — send a trailing Enter keypress after the literal text
- `--pane <id>` — target a specific pane (defaults to the calling pane via `$TMUX_PANE`)

**JSON-RPC**
- Method: `input.send_text`
- Params: `{ "text": "ls -la", "enter": true, "pane_id": "%5" }` _(`enter` and `pane_id` are optional)_
- Response: `{ "ok": true }`

---

#### `send-key <key>`

Send a named key press to the active pane, or a specific pane with `--pane`.

Supported keys: `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `space`

```bash
gallager send-key enter
gallager send-key escape --pane %3
```

**JSON-RPC**
- Method: `input.send_key`
- Params: `{ "key": "enter", "pane_id": "%3" }` _(pane_id is optional)_
- Response: `{ "ok": true }`

---

### Notifications

#### `notify`

Send a desktop notification through Gallager's notification system. Notifications appear identically to terminal-triggered ones. If `$TMUX_PANE` is set, the notification includes pane context so tapping it navigates to that pane.

```bash
gallager notify --title "Deploy done" --body "Production updated successfully"
gallager notify --title "Alert" --subtitle "CI" --body "Tests failed on main"
```

**JSON-RPC**
- Method: `notification.create`
- Params: `{ "title": "Deploy done", "body": "Production updated successfully", "subtitle": "CI" }` _(subtitle is optional)_
- Response: `{ "ok": true }`

---

### Projects

#### `list-projects`

List all Claude Code projects discovered on the host. Projects are gathered from `~/.claude.json` and any additional folders configured under **Settings → Additional Claude Folders**, then sorted by most recently used.

```bash
gallager list-projects
gallager list-projects --json | jq -r '.result.projects[].path'
```

Default output is `<name>\t<path>` per line. Use `--json` for the full record (including `last_used`).

**JSON-RPC**
- Method: `project.list`
- Params: _(none)_
- Response:
```json
{
  "id": "10",
  "ok": true,
  "result": {
    "projects": [
      { "id": "/Users/me/code/foo", "name": "foo", "path": "/Users/me/code/foo", "last_used": "2026-04-19T12:34:56.789Z" },
      { "id": "/Users/me/code/bar", "name": "bar", "path": "/Users/me/code/bar", "last_used": null }
    ]
  }
}
```

---

#### `start-project <path> [-- <args…>]`

Create a new tmux session for a Claude project and run `claude` in it. The session is named after the last path component, the working directory is set to `<path>`, and the configured claude command (default `claude`, see **Settings → Claude command**) is launched in the new pane.

Any positional arguments after `--` are appended verbatim to the claude command line — useful for `--resume`, `--continue`, model selection, etc.

```bash
gallager start-project ~/code/foo
gallager start-project ~/code/foo -- --resume
gallager start-project ~/code/foo -- --model claude-sonnet-4-6
```

Unlike `new-session --path`, this command **always** runs claude regardless of the **Auto-run Claude in project folders** setting.

**JSON-RPC**
- Method: `project.start`
- Params: `{ "path": "~/code/foo", "args": ["--resume"] }` _(args is optional)_
- Response:
```json
{
  "id": "11",
  "ok": true,
  "result": { "id": "foo", "name": "foo", "windowCount": 1, "isAttached": false }
}
```
- Errors: `not_found` if `path` does not exist or is not a directory.

---

### Editor

#### `edit <file>`

Open a file in Gallager's in-app prompt editor. The command blocks until the user submits or cancels in the app, then exits with the result. The calling pane is detected automatically from `$TMUX_PANE`.

This command is used as the `$VISUAL` editor inside Gallager-managed sessions, enabling Claude Code's prompt editing flow.

```bash
gallager edit /tmp/my-prompt.txt
```

**JSON-RPC**
- Method: `editor.open`
- Params: `{ "pane_id": "%3", "file_path": "/tmp/my-prompt.txt" }`
- Response: `{ "ok": true }` _(sent when editing completes)_

---

### Utility

#### `ping`

Check whether Gallager is running and the socket is reachable.

```bash
gallager ping
```

**JSON-RPC**
- Method: `system.ping`
- Params: _(none)_
- Response: `{ "pong": true }`

---

#### `wait-ready`

Block until Gallager responds to `ping`, or fail after a timeout. Useful in login-time scripts that fire before the app finishes launching — replaces a hand-rolled poll loop around `gallager ping`.

```bash
gallager wait-ready                  # default 30s timeout, 0.2s interval
gallager wait-ready --timeout 60     # wait up to 60 seconds
```

**Options**
- `--timeout <seconds>` — maximum wait (default `30`)
- `--interval <seconds>` — poll interval (default `0.2`)

Exits 0 on first successful ping; exits non-zero with an error message on timeout. This command is implemented entirely in the CLI — there is no `system.wait_ready` RPC method.

---

#### `capabilities`

List all JSON-RPC methods supported by the running app version.

```bash
gallager capabilities
gallager capabilities --json | jq '.result.methods[]'
```

**JSON-RPC**
- Method: `system.capabilities`
- Params: _(none)_
- Response:
```json
{
  "id": "8",
  "ok": true,
  "result": {
    "methods": [
      "session.list", "session.create", "session.select", "session.current", "session.close",
      "session.set_state", "session.set_title",
      "window.list", "window.create", "window.select", "window.close",
      "pane.list", "pane.split", "pane.select", "pane.capture",
      "input.send_text", "input.send_key",
      "notification.create",
      "editor.open",
      "project.list", "project.start",
      "system.ping", "system.capabilities", "system.identify"
    ]
  }
}
```

---

#### `identify`

Show the session, window, and pane context of the calling process. Uses `$TMUX_PANE` to determine context. Useful for scripts that need to know where they are running.

```bash
gallager identify
```

**JSON-RPC**
- Method: `system.identify`
- Params: _(none)_
- Response:
```json
{
  "id": "9",
  "ok": true,
  "result": {
    "session": { "id": "main", "name": "main", "windowCount": 2, "isAttached": true },
    "window":  { "id": "main:0", "index": 0, "name": "editor", "paneCount": 2, "isActive": true, "sessionId": "main" },
    "pane":    { "id": "%3", "index": 0, "isActive": true, "command": "claude", "cwd": "/Users/me/project", "width": 220, "height": 50, "windowId": "main:0", "hasClaudeSession": true }
  }
}
```

---

## Global Options

| Option | Description |
|--------|-------------|
| `--socket <path>` | Override the socket path (takes priority over `$GALLAGER_SOCKET` and the default fallback) |
| `--json` | Print the raw JSON-RPC response instead of formatted output |
| `--pane <id>` | Target a specific pane by tmux pane ID (e.g. `%3`). Overrides the active pane for input commands |
| `--session <id>` | Target a specific session. Used by `list-windows`, `new-window` |
| `--window <id>` | Target a specific window. Used by `list-panes` |

---

## Wire Protocol

`gallager` communicates with the app using newline-delimited JSON-RPC over a Unix domain socket (`AF_UNIX, SOCK_STREAM`). Each message is a single JSON object followed by `\n`. Connections are persistent — multiple requests can be sent over a single connection.

### Request

```json
{ "id": "unique-id", "method": "session.list", "params": {} }
```

- `id` — arbitrary string, echoed in the response for correlation
- `method` — dot-separated `domain.action` string
- `params` — object with method-specific fields (may be empty `{}`)

### Success Response

```json
{ "id": "unique-id", "ok": true, "result": { ... } }
```

### Error Response

```json
{
  "id": "unique-id",
  "ok": false,
  "error": { "code": "not_found", "message": "Session 'foo' not found" }
}
```

### Method Naming

Methods follow a `domain.action` convention:

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

---

## Error Codes

| Code | Meaning |
|------|---------|
| `not_found` | The requested resource (session, window, pane) does not exist |
| `invalid_params` | A required parameter is missing or has an invalid value |
| `method_not_found` | The requested method string is not recognized |
| `internal_error` | An unexpected error occurred inside the app |
