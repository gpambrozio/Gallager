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

# Same notification, also pushed to paired iOS devices
gallager notify --title "Build done" --body "Tests passed" --push

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

Create a new tmux session. Use `--path` to set the starting directory for the first pane; if omitted, the session opens in the user's home directory. Use `--title` to set the sidebar description and `--color` to set the sidebar dot at creation time so a single command lands the session fully labelled.

```bash
gallager new-session
gallager new-session --name myproject
gallager new-session --name myproject --path /Users/me/code/myproject
gallager new-session --name myproject --title "My project" --color blue
```

Valid colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `gray`. Aliases `violet` (→ purple), `magenta` (→ pink), and `grey` (→ gray) are accepted; case is ignored.

**JSON-RPC**
- Method: `session.create`
- Params: `{ "name": "myproject", "path": "/Users/me/code/myproject", "title": "My project", "color": "blue" }` _(all optional; `path` defaults to `$HOME`; unknown color names return `invalid_params`)_
- Response:
```json
{
  "id": "2",
  "ok": true,
  "result": { "id": "myproject", "name": "myproject", "windowCount": 1, "isAttached": false }
}
```

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

#### `set-title <text>`

Set or clear the sidebar title for a session. The title is persisted as the `@gallager-description` tmux user option so it survives an app restart. Pass an empty string to clear.

Titles always apply at session scope — every window in the session shows the same title. To rename the tab label of a single window, use [`rename-window`](#rename-window-id-name) instead.

```bash
gallager set-title "Workers" --session work    # explicit session
gallager set-title "Builds"                    # current pane's session via $TMUX_PANE
gallager set-title ""                          # clear
```

**JSON-RPC**
- Method: `session.set_title`
- Params: `{ "title"?: string, "session_id"?: string, "pane_id"?: string }` _(omit or pass empty `title` to clear; `pane_id` is used to look up the calling pane's session and is sent automatically from `$TMUX_PANE` when no flag is given)_
- Response: `{ "ok": true }`

---

#### `set-color <color>`

Set or clear the sidebar dot for a session. The choice is persisted as the `@gallager-color` tmux user option so it survives an app restart. Pass `none` (or an empty string) to clear.

Like `set-title`, colors always apply at session scope.

```bash
gallager set-color blue --session work          # explicit session
gallager set-color purple                       # current pane's session via $TMUX_PANE
gallager set-color none                         # clear
```

Valid colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `gray` (plus the `violet`/`magenta`/`grey` aliases accepted by `new-session --color`).

**JSON-RPC**
- Method: `session.set_color`
- Params: `{ "color": string, "session_id"?: string, "pane_id"?: string }` _(empty `color` clears; unknown colors return `invalid_params`)_
- Response: `{ "ok": true }`

---

#### `set-emoji <emoji-or-name>`

Set or clear the sidebar emoji icon for a session. The choice is persisted as the `@gallager-emoji` tmux user option so it survives an app restart. Pass `none` (or an empty string) to clear.

Like `set-title` and `set-color`, emoji icons always apply at session scope. The argument accepts either an emoji character directly (`"🚀"`, `"🐛"`) or a Unicode name / description (`rocket`, `bug`, `"smiling face heart"`). Name lookup uses `Unicode.Scalar.Properties.name` locally — an exact match short-circuits to a single result, ambiguous queries print the candidate glyphs with their names and exit non-zero so you can rerun with a more specific phrase. Use `find-emoji` to browse matches without committing. Input that's neither an emoji nor a recognised Unicode name is rejected with a validation error so arbitrary text doesn't get persisted.

```bash
gallager set-emoji "🚀" --session work          # literal emoji character
gallager set-emoji rocket --session work        # same — looked up by Unicode name
gallager set-emoji "smiling face heart"         # any word-set substring of a Unicode name works
gallager set-emoji "🐛"                         # current pane's session via $TMUX_PANE
gallager set-emoji none                         # clear
```

**JSON-RPC**
- Method: `session.set_emoji`
- Params: `{ "emoji": string, "session_id"?: string, "pane_id"?: string }` _(empty `emoji` clears)_
- Response: `{ "ok": true }`

---

#### `find-emoji <query>`

Search the Unicode emoji database by name and print one match per line as `<glyph>  <name>`. Every whitespace-separated word in the query must appear in the candidate's name (case-insensitive); results are sorted shortest-name-first so the most canonical candidate floats to the top. Pure local lookup — this command does not contact the relay or tmux, so it works even when Gallager isn't running.

```bash
gallager find-emoji rocket
gallager find-emoji "smiling face"
gallager find-emoji heart --json
```

With `--json` the output is a JSON array of `{ "emoji", "name" }` entries. An empty match set is `[]` with exit 0 (so scripts can pipe through `jq`); the human-readable mode exits 1 with a stderr message instead so shell branches like `if gallager find-emoji foo > /dev/null` work the way you'd expect.

**JSON-RPC**: this command is CLI-only — no JSON-RPC method, since name lookup happens entirely in the CLI process.

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

Create a new window in the current session, or a specific session with `--session`. Use `--path` to set the starting directory for the new window; if omitted, it opens in the user's home directory. Use `--name` to set the tmux window name (tab label) — without it, the daemon auto-generates `terminal N`. To change the tab label later, use [`rename-window`](#rename-window-id-name).

```bash
gallager new-window
gallager new-window --session work
gallager new-window --session work --path /Users/me/code/work
gallager new-window --name editor
```

**JSON-RPC**
- Method: `window.create`
- Params: `{ "session_id": "work", "path": "/Users/me/code/work", "name": "editor" }` _(all optional; `path` defaults to `$HOME`)_
- Response:
```json
{
  "id": "5",
  "ok": true,
  "result": { "id": "work:1", "index": 1, "name": "bash", "paneCount": 1, "isActive": false, "sessionId": "work" }
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

#### `rename-window <id> <name>`

Set a window's tmux name (the tab label). The only window-scoped CLI mutation — for the session-wide sidebar title, use [`set-title`](#set-title-text). Empty names are rejected.

Under the hood this calls `tmux rename-window`, which also disables tmux's automatic-rename for that window so the tab stops tracking the running command.

```bash
gallager rename-window work:1 logs
```

**JSON-RPC**
- Method: `window.set_name`
- Params: `{ "window_id": "work:1", "name": "logs" }`
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
        "windowId": "main:0", "hasAgentSession": true
      }
    ]
  }
}
```

---

#### `split-pane [direction]`

Split the current pane. Direction is `left`, `right`, `up`, or `down` (default: `right`). Use `--pane` to target a specific pane. Use `--path` to set the starting directory for the new pane; if omitted, it opens in the user's home directory. Use `--shell` to run a custom shell or command as the new pane's process instead of the default shell — useful for spinning up a fish, nushell, or bespoke command pane.

```bash
gallager split-pane
gallager split-pane down
gallager split-pane right --pane %3
gallager split-pane down --path /Users/me/code/work
gallager split-pane right --shell /opt/homebrew/bin/fish
```

**JSON-RPC**
- Method: `pane.split`
- Params: `{ "direction": "down", "pane_id": "%3", "path": "/Users/me/code/work", "shell": "/bin/fish" }` _(all optional; `path` defaults to `$HOME`)_
- Response:
```json
{
  "id": "7",
  "ok": true,
  "result": {
    "id": "%6", "index": 1, "isActive": false,
    "command": "bash", "cwd": "/Users/me/project",
    "width": 220, "height": 24,
    "windowId": "main:0", "hasAgentSession": false
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

#### `set-progress <value>`

Set or clear the per-pane sidebar progress bar that the host normally derives from `OSC 9;4` terminal sequences. The override syncs through the same path the OSC reader uses, so every connected viewer (host sidebar, Mac viewer, iOS) sees the same bar.

CLI and OSC updates share `PaneState.progress` and last-write-wins each other — a script can set the bar before kicking off a task, and a subsequent `OSC 9;4` sequence emitted by the running program replaces it (and vice versa).

```bash
gallager set-progress 50                  # 50% determinate (blue)
gallager set-progress 75 --pane %3        # explicit pane target
gallager set-progress indeterminate       # animated blue scanner (no specific %)
gallager set-progress warning             # full yellow warning bar
gallager set-progress error               # full red error bar
gallager set-progress clear               # remove the bar (alias: none, "")
```

Accepted values: `0`–`100` (with or without a trailing `%`), `indeterminate`, `warning`, `error`, `clear` / `none` / empty string.

**JSON-RPC**
- Method: `pane.set_progress`
- Params: `{ "value": "50", "pane_id": "%3" }` _(pane_id is optional; the CLI fills it from `$TMUX_PANE` when no `--pane` flag is given)_
- Response: `{ "ok": true }`

This value can also be set declaratively inside `gallager apply` YAML — set `progress: 50` (or `progress: warning`, `progress: indeterminate`) on a pane spec to apply the value at session-creation time. Re-applying syncs the value (and clearing the field clears the bar).

---

### Input

#### `send <text>`

Send text to the active pane, or a specific pane with `--pane`. The text is sent as-is — include `\n` for a newline (Enter).

```bash
gallager send "ls -la\n"
gallager send "hello" --pane %5
```

**JSON-RPC**
- Method: `input.send_text`
- Params: `{ "text": "ls -la\n", "pane_id": "%5" }` _(pane_id is optional)_
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

Pass `--push` to also forward the notification to every paired iOS viewer through the relay server. This reuses the same encrypted-push pipeline that Claude hook events use, so the alert falls back to APNs whenever the viewer is offline. Without `--push` the notification stays local to macOS Notification Center.

```bash
gallager notify --title "Deploy done" --body "Production updated successfully"
gallager notify --title "Build green" --body "All checks passed" --push
```

**JSON-RPC**
- Method: `notification.create`
- Params: `{ "title": "Deploy done", "body": "Production updated successfully", "push": true }` _(`push` is optional)_
- Response: `{ "ok": true }`

---

### Layouts

#### `apply <file>`

Build a tmux session from a declarative YAML or JSON layout file. Idempotent by default — re-applying selects an existing session instead of duplicating it. The schema is a strict superset of [tmuxp](https://tmuxp.git-pull.com)'s YAML; existing tmuxp configs work without modification.

```bash
gallager apply workers.yml
gallager apply ~/projects/foo --rebuild       # close-then-build
gallager apply layout.yml --detach            # don't switch
gallager apply layout.yml --dry-run           # parse + plan, no tmux
gallager apply layout.yml --lenient           # warn on unknown keys
gallager apply layout.yml --require-create    # exit 3 if session exists
gallager apply -                              # read from stdin
envsubst < layout.tmpl.yml | gallager apply -
```

When the file argument is a directory, gallager looks for `.gallager.yaml`, `.gallager.yml`, `.tmuxp.yaml`, `.tmuxp.yml` (in that order).

**Exit codes**
- `0` — applied (built or selected)
- `1` — generic failure (parse error, RPC failure)
- `2` — validation error (schema invalid, unknown required field)
- `3` — already exists, in `--require-create` mode

**File format**

```yaml
session_name: workers           # required
description: "Worker scripts"   # sidebar description (Gallager extension)
color: blue                     # sidebar dot color (Gallager extension); omit or "" to leave unset
start_directory: ~/code         # default cwd; relative resolves against the file's dir
environment:                    # tmux set-environment for the session
  FOO: bar
shell_command_before:           # commands prepended to every pane (string or array)
  - source ~/.env
before_script: ./bootstrap.sh   # ran once before the session is created (cold start only)
options: {}                     # tmux session options — passed through
suppress_history: true          # default for all panes; prefix sent commands with " "
windows:
  - window_name: editor         # also accepted: `name`
    layout: main-vertical
    focus: true
    options: {}
    panes:
      - vim                     # bare string = shell_command
      - shell_command: ["tail -f log"]
        start_directory: ./logs
        progress: 50            # Gallager extension; 0-100, indeterminate, warning, error, or clear
      - claude:                 # Gallager extension
          project: ~/code/foo
          args: ["--resume"]
on_create:                      # cold-start hooks (run once)
  - "echo bootstrap >> /tmp/log"
on_apply:                       # always-run hooks
  - "gallager notify --title workers --body 'ready'"
```

Variable expansion: every string-valued field is run through a `${VAR}` / `$VAR` expander. `${VAR:-default}` provides inline defaults. No command substitution, no ERB.

**JSON-RPC**
- Method: `layout.apply`
- Params: `{ "config": <parsed YAML/JSON>, "rebuild": false, "detach": false, "dry_run": false, "lenient": false, "require_create": false, "config_path": "/abs/path/to/file.yaml" }`
- Response:
```json
{
  "id": "10",
  "ok": true,
  "result": {
    "session_name": "workers",
    "created": true,
    "warnings": [],
    "planned_actions": ["session.create name=workers path=$HOME", "..."]
  }
}
```

---

### Plugins

The `plugin` namespace manages installed Gallager plugins (Spec §17.4). Bundled plugins (Claude Code, Codex CLI) ship inside the app and cannot be uninstalled — only disabled. User-installed plugins (via `gallager plugin install`) can be removed, but the v1 install flow has no signing/trust UI yet; pass `--yes` to skip the confirmation prompt and accept the v2 follow-up work.

All `plugin.*` RPC methods accept `--json` for structured output and exit non-zero on failure. Network errors talking to the sidecar surface as `internal_error`. Missing plugin ids surface as `internal_error` with the message `"PluginManager has no plugin with id '<id>'"`.

#### `plugin list`

Print every installed plugin: id, version, enabled flag, and source. Default output is tab-separated for easy `cut`/`awk` pipelines.

```bash
gallager plugin list
gallager plugin list --json
```

Sample output (default):
```
claude-code	1.0.0	enabled	bundled
codex-cli	1.0.0	enabled	bundled
```

**JSON-RPC**
- Method: `plugin.list`
- Params: _(none)_
- Response:
```json
{
  "id": "1",
  "ok": true,
  "result": {
    "plugins": [
      { "id": "claude-code", "version": "1.0.0", "enabled": true, "source": "bundled" },
      { "id": "codex-cli", "version": "1.0.0", "enabled": true, "source": "bundled" }
    ]
  }
}
```

---

#### `plugin info <id>`

Show the full record for a single plugin: manifest fields, install/state paths, log file location, state-dir size, and the running bit.

```bash
gallager plugin info claude-code
gallager plugin info claude-code --json
```

**JSON-RPC**
- Method: `plugin.info`
- Params: `{ "id": "claude-code" }`
- Response:
```json
{
  "id": "2",
  "ok": true,
  "result": {
    "id": "claude-code",
    "version": "1.0.0",
    "enabled": true,
    "source": "bundled",
    "install_dir": "/Applications/Gallager.app/Contents/Resources/plugins/claude-code",
    "state_dir": "/Users/me/.gallager/state/plugins/claude-code",
    "state_dir_size_bytes": 4096,
    "log_file": "/Users/me/.gallager/state/plugins/claude-code/logs/sidecar.log",
    "running": true,
    "display_name": "Claude Code",
    "publisher": "Anthropic",
    "process_names": ["claude"],
    "capabilities": {
      "pushes_projects": true,
      "translate_event": true,
      "install": true,
      "detect_pane": false,
      "requires_rich_detection": false,
      "settings_schema": "sidecar"
    }
  }
}
```

---

#### `plugin install <url>`

Install a plugin from an https manifest URL. The CLI prompts on stdin for confirmation; pass `--yes` to skip the prompt (e.g. for scripts).

```bash
gallager plugin install https://example.com/plugins/my-plugin/plugin.json
gallager plugin install https://example.com/plugins/my-plugin/plugin.json --yes
```

The app fetches the manifest, downloads `bundle.zip` from the same directory, verifies its SHA-256 against the manifest, unpacks it into `~/.gallager/plugins/<id>/`, adds a registry entry, and spawns the sidecar. Schema mismatches and SHA-256 failures abort the install and return an error.

v1 does **not** implement the trust UI / signature verification described in Spec §16. The CLI's `--yes` flag accepts the v2 follow-up work — once trust is in place the flag will continue to mean "skip the confirmation step", but the underlying flow gains a signing check.

**JSON-RPC**
- Method: `plugin.install`
- Params: `{ "manifest_url": "https://…/plugin.json", "yes": true }`
- Response: `{ "ok": true }`

---

#### `plugin remove <id>`

Uninstall a URL-installed plugin. Bundled plugins refuse and surface an `internal_error` — disable them via [`plugin disable`](#plugin-disable-id) instead.

```bash
gallager plugin remove my-plugin
gallager plugin remove my-plugin --keep-state    # leave logs + settings on disk
gallager plugin remove my-plugin --delete-state  # explicit (v1 default)
```

v1 always removes the plugin's state dir on uninstall; `--keep-state` is accepted for forward compatibility but ignored by the app today. v2 will honor the flag.

**JSON-RPC**
- Method: `plugin.remove`
- Params: `{ "id": "my-plugin", "delete_state": true }`
- Response: `{ "ok": true }`

---

#### `plugin enable <id>`

Spawn a previously-disabled plugin's sidecar and reload its presentation bundle. Idempotent.

```bash
gallager plugin enable claude-code
```

**JSON-RPC**
- Method: `plugin.enable`
- Params: `{ "id": "claude-code" }`
- Response: `{ "ok": true }`

---

#### `plugin disable <id>`

Shut down a plugin's sidecar without uninstalling it. The plugin's files stay on disk; re-running `gallager plugin enable <id>` brings it back.

```bash
gallager plugin disable claude-code
```

**JSON-RPC**
- Method: `plugin.disable`
- Params: `{ "id": "claude-code" }`
- Response: `{ "ok": true }`

---

#### `plugin update [<id>]`

Check for plugin updates. With `--apply`, apply available updates immediately.

```bash
gallager plugin update                  # check every plugin
gallager plugin update claude-code      # check one
gallager plugin update --apply          # apply (v2)
```

**v1 limitation:** no auto-update mechanism exists. The app always returns an empty update list and the CLI prints `No updates available.` regardless of `--apply`. The `--apply` flag is parsed for forward compatibility with v2's installer.

**JSON-RPC**
- Method: `plugin.update`
- Params: `{ "id": "claude-code" }` _(both fields optional)_
- Response:
```json
{ "id": "3", "ok": true, "result": { "updates": [] } }
```

---

#### `plugin call <id> <method> [<json>]`

Send a raw JSON-RPC request directly to a plugin's sidecar — bypasses the manager's translation/routing layer. Intended for plugin authors debugging their own methods.

JSON params come from the trailing argument or stdin:

```bash
gallager plugin call claude-code _test_push_set_projects
gallager plugin call claude-code translate_event '{"context":{}}'
echo '{"context":{}}' | gallager plugin call claude-code translate_event
```

Default output is just the result payload (unwrapped from the JSON-RPC envelope) so the response can be piped straight into `jq`. With `--json` the full envelope is printed.

**JSON-RPC**
- Method: `plugin.call`
- Params: `{ "id": "claude-code", "method": "translate_event", "params": {...} }`
- Response: `{ "result": <sidecar response> }`

---

#### `plugin logs <id> [-f] [--lines N]`

Print the trailing lines from a plugin's `sidecar.log`. `-f` (alias `--follow`) tails by polling the file once per second and emitting any newly-appended content.

```bash
gallager plugin logs claude-code              # last 256 lines
gallager plugin logs claude-code --lines 50
gallager plugin logs claude-code -f           # follow
```

The log path matches the in-app log viewer (`~/.gallager/state/plugins/<id>/logs/sidecar.log`). Size rotation is 5 MB; rotated files (`sidecar.log.1`) are not surfaced by this RPC — only the active file.

**JSON-RPC**
- Method: `plugin.logs`
- Params: `{ "id": "claude-code", "lines": 256 }`
- Response: `{ "content": "<line>\n<line>\n…" }` _(empty when the log doesn't exist yet)_

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
      "session.set_state", "session.set_title", "session.set_color",
      "window.list", "window.create", "window.select", "window.close", "window.set_name",
      "pane.list", "pane.split", "pane.select", "pane.capture", "pane.set_layout", "pane.set_progress",
      "input.send_text", "input.send_key",
      "notification.create",
      "editor.open",
      "system.ping", "system.capabilities", "system.identify", "system.set_env",
      "project.list", "project.start",
      "layout.apply",
      "plugin.list", "plugin.info", "plugin.install", "plugin.remove",
      "plugin.enable", "plugin.disable", "plugin.update", "plugin.call", "plugin.logs"
    ]
  }
}
```

---

#### `system.set_env` (RPC-only)

Set or unset session-scoped tmux environment variables. New shells spawned in the session inherit the values; already-running panes keep their existing environment. Used internally by `gallager apply` to honor the `environment:` block in a layout config.

**JSON-RPC**
- Method: `system.set_env`
- Params: `{ "session_id": "workers", "vars": { "FOO": "bar", "OLD": null } }` _(value `null` unsets the variable)_
- Response: `{ "ok": true }`

---

#### `pane.set_layout` (RPC-only)

Apply a tmux layout (preset name or hex layout string) to a window. Used internally by `gallager apply` for `windows[].layout:` but also useful for scripted retiling.

**JSON-RPC**
- Method: `pane.set_layout`
- Params: `{ "target": "workers:0", "layout": "main-vertical" }`
- Response: `{ "ok": true }`

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
    "pane":    { "id": "%3", "index": 0, "isActive": true, "command": "claude", "cwd": "/Users/me/project", "width": 220, "height": 50, "windowId": "main:0", "hasAgentSession": true }
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
| `--session <id>` | Target a specific session. Used by `list-windows`, `new-window`, `set-title`, `set-color`, `set-emoji` |
| `--window <id>` | Target a specific window. Used by `list-panes` |
| `--path <dir>` | Starting directory for `new-session`, `new-window`, and `split-pane`. Defaults to `$HOME` when omitted. |
| `--name <name>` | tmux window name (tab label) for `new-window`. Without it, the daemon auto-generates `terminal N`. |
| `--shell <cmd>` | Run this command/shell as the new pane's process for `split-pane`. |

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
| `plugin.*` | Plugin management |
| `system.*` | Utility / introspection |

---

## Error Codes

| Code | Meaning |
|------|---------|
| `not_found` | The requested resource (session, window, pane) does not exist |
| `invalid_params` | A required parameter is missing or has an invalid value |
| `method_not_found` | The requested method string is not recognized |
| `validation_error` | `layout.apply` config failed schema validation (CLI maps to exit 2) |
| `session_exists` | `layout.apply` was called with `require_create` and the session already exists (CLI maps to exit 3) |
| `internal_error` | An unexpected error occurred inside the app |
