---
name: gallager-cli
description: Control the Gallager macOS app from the command line to manage tmux sessions, windows, panes, send text/keys to terminals, trigger desktop notifications, and open files in the in-app prompt editor. Use this skill whenever the user is working inside a Gallager-managed tmux session and wants to drive the UI from scripts or the shell — creating sessions, switching panes, sending input, notifying when a long-running task finishes, or editing prompts from the current terminal. Trigger on phrases like "open a new tmux window", "send this to the pane", "notify me when build finishes", "split pane", "edit this prompt in Gallager", or any mention of the `gallager` CLI.
---

# Gallager CLI

`gallager` is a command-line tool that talks to the Gallager macOS app (which manages tmux sessions) over a Unix socket. Use it to drive the app from scripts, terminals, or automated workflows: list/create/close sessions, windows, and panes; send text or key presses; post desktop notifications; and open files in the in-app prompt editor.

## Gallager is tmux underneath

Gallager does not run its own terminal multiplexer — it drives the real `tmux` binary on the user's machine and surfaces the state. That has two practical consequences:

1. **Every ID Gallager hands you is a tmux primitive.** You can paste them straight into `tmux` commands.
   - Session IDs (e.g. `main`, `work`) are tmux session names → use with `tmux … -t main`.
   - Window IDs (e.g. `main:0`, `work:1`) are tmux `session:index` targets → use with `tmux … -t main:0`.
   - Pane IDs (e.g. `%3`, `%17`) are tmux pane IDs → use with `tmux … -t %3`.
   - Fields like `windowId`, `sessionId` on the returned objects point into the same namespace.
2. **`tmux` is the escape hatch when `gallager` lacks a command.** Anything `tmux` can do to these sessions, you can do too — rename a window, swap panes, resize by percentage, set options, kill a stuck pane, attach from another terminal, run `tmux capture-pane`, etc. Gallager observes tmux state continuously, so changes you make with `tmux` show up in the app automatically; there's no "refresh" to run.

Prefer the `gallager` subcommand when one exists (it goes through the app and keeps the UI in sync for things like `select-session` that affect the foreground view). Reach for raw `tmux` for operations Gallager doesn't expose.

### Mapping `gallager` to `tmux`

| Gallager output/command | tmux equivalent |
|---|---|
| `list-sessions` / `current-session` | `tmux list-sessions`, `tmux display -p '#S'` |
| `new-session --name foo` | `tmux new-session -d -s foo` |
| `set-title --session foo "text"` | `tmux set-option -t foo @gallager-description "text"` |
| `set-color --session foo blue` | `tmux set-option -t foo @gallager-color blue` |
| `set-emoji --session foo "🚀"` | `tmux set-option -t foo @gallager-emoji "🚀"` |
| `select-session foo` / `close-session foo` | `tmux switch-client -t foo` / `tmux kill-session -t foo` |
| `list-windows [--session foo]` | `tmux list-windows [-t foo]` |
| `new-window` / `select-window foo:1` / `close-window foo:1` | `tmux new-window` / `tmux select-window -t foo:1` / `tmux kill-window -t foo:1` |
| `rename-window foo:1 logs` | `tmux rename-window -t foo:1 logs` |
| `list-panes [--window foo:0]` | `tmux list-panes [-t foo:0]` (add `-a` for every pane on the server) |
| `split-pane right` | `tmux split-window -h` (horizontal = right; `-v` = down) |
| `select-pane %3` | `tmux select-pane -t %3` |
| `send "text" --pane %3` | `tmux send-keys -t %3 -l "text"` |
| `send "text" --enter --pane %3` | `tmux send-keys -t %3 -l "text" \; send-keys -t %3 Enter` |
| `send-key enter --pane %3` | `tmux send-keys -t %3 Enter` |
| `capture-pane --pane %3` | `tmux capture-pane -t %3 -p` (add `--scrollback` for `-S -`) |
| Pane field `command` / `cwd` | `tmux display -p -t %3 '#{pane_current_command}'` / `'#{pane_current_path}'` |

### When you must go straight to tmux

Examples of things `gallager` does not expose but tmux handles fine:

```bash
# Rename a session (windows have `gallager rename-window`)
tmux rename-session -t work "client-work"

# Resize a pane by percentage (gallager only splits)
tmux resize-pane -t %5 -x 30% -y 40%

# Capture a pane's visible buffer (handy for scraping output)
tmux capture-pane -t %3 -p

# Swap two panes, join a pane into another window, break a pane out
tmux swap-pane -s %3 -t %5
tmux join-pane   -s %3 -t main:1
tmux break-pane  -s %3

# Toggle zoom, kill a stuck pane, set a layout
tmux resize-pane -Z -t %3
tmux kill-pane -t %3
tmux select-layout -t main:0 tiled
```

After any of these, Gallager's session/window/pane list updates on its own — no need to tell the app.

### Picking the right tmux server

Inside a Gallager-managed pane, the `$TMUX` env var is already set, so plain `tmux …` talks to the correct server automatically. If you're running `tmux` from *outside* a managed pane (or the user has configured a custom socket in Gallager's settings), pass `-S <socket-path>` to match the server Gallager uses — otherwise you'll hit the user's default tmux server instead. `gallager identify` / `gallager list-sessions` confirm you're looking at the right server.

## When to reach for it

- The user is inside a Gallager-managed tmux session (usually detected by `$GALLAGER_SOCKET` being set) and wants to do anything UI-related without clicking.
- A script wants to notify the user through Gallager's notification channel so taps on the phone jump back to the right pane.
- You need to script pane layouts (e.g., spin up a session with three panes for build/test/log) instead of doing it by hand.
- You want to automate "send `make test` to that pane and press Enter" without leaving the current terminal.

If `gallager` is not on `PATH`, ask the user to run **Gallager menu → Install Command Line Tool…** once. That installs `/usr/local/bin/gallager`.

## Core mental model

Every command is one of: `list-*` (inspect), `new-*` / `split-pane` / `start-project` (create), `select-*` (focus), `close-*` (destroy), `rename-window` (relabel a tab), `send` / `send-key` (input), `set-title` / `set-color` / `set-emoji` / `session-state` / `set-progress` (label), `capture-pane` (read), `find-emoji` (local Unicode lookup), `notify` (alert), `edit` (block on prompt editor), or a utility (`ping`, `capabilities`, `identify`, `wait-ready`).

Commands default to the **current** session/window/pane (inferred from the calling shell's `$TMUX_PANE`). Override with `--session <id>`, `--window <id>`, or `--pane <id>` when targeting something else. (`set-title`, `set-color`, and `set-emoji` are session-only — they accept `--session` but not `--window` or `--pane`.)

Append `--json` to any command to get raw JSON-RPC output suitable for `jq`. Use human-readable output when the user will read it directly; use `--json` when piping into other commands.

## Quick reference

```bash
# Sanity check
gallager ping                              # → "pong" if app is running
gallager wait-ready --timeout 30           # block until app reachable; non-zero exit on timeout
gallager identify                          # Show current session/window/pane
gallager capabilities                      # List every supported method

# Sessions
gallager list-sessions
gallager new-session --name work --path ~/code/proj
gallager new-session --name work --if-missing             # idempotent: returns existing session info, `created: false`
gallager new-session --name work --title "Work"           # set sidebar title at creation time
gallager new-session --name work --color blue             # set sidebar dot at creation time
gallager set-title "Work" --session work                  # set/replace sidebar title (empty string clears)
gallager set-title ""                                     # default targets calling pane's session via $TMUX_PANE
gallager set-color blue --session work                    # set/replace sidebar dot color (none/empty clears)
gallager set-color none                                   # clear color on calling pane's session
gallager set-emoji "🚀" --session work                    # set/replace sidebar emoji icon (none/empty clears)
gallager set-emoji rocket --session work                  # same — looks up emoji by name/keyword
gallager set-emoji trash --session work                   # keyword synonyms work too → 🗑️ (named WASTEBASKET)
gallager set-emoji none                                   # clear emoji on calling pane's session
gallager find-emoji trash                                 # search by name or CLDR keyword — prints "<glyph>  <name>"
gallager find-emoji rocket --json                         # JSON array; empty match set is `[]` with exit 0
gallager select-session work
gallager current-session
gallager close-session work
gallager session-state working --session work    # working | idle | waiting | clear

# Windows (default to current session)
gallager list-windows
gallager list-windows --session work
gallager new-window                        # --session <id>, --path <dir>, --name <tab-label>
gallager select-window main:1
gallager rename-window main:1 logs         # set tmux window name (tab label) — empty name rejected
gallager close-window main:1

# Panes (default to current window)
gallager list-panes
gallager split-pane right                  # left | right | up | down
gallager split-pane down --pane %3 --path ~/logs
gallager select-pane %3
gallager capture-pane                      # plain text of visible buffer (calling pane)
gallager capture-pane --pane %3 --scrollback   # include full scrollback history
gallager set-progress 50                   # blue determinate bar at 50% on calling pane
gallager set-progress 75 --pane %3         # explicit pane target
gallager set-progress indeterminate        # animated blue scanner (no specific %)
gallager set-progress warning              # full yellow warning bar
gallager set-progress error                # full red error bar
gallager set-progress clear                # remove the bar (alias: none, "")

# Input — `send` is raw (include \n yourself or pass --enter); `send-key` is named
gallager send $'make test\n'               # Bash: $'...' expands \n
gallager send "make test" --enter          # appends a real Enter keypress after the text
gallager send "hello" --pane %5            # no newline sent
gallager send-key enter                    # enter|tab|escape|backspace|delete|up|down|left|right|space

# Notifications (tapping on iOS jumps back to the calling pane if $TMUX_PANE is set)
gallager notify --title "Build done" --body "All tests passed"
gallager notify --title "Build done" --body "All tests passed" --push  # also push to paired iOS devices

# Prompt editor (blocks until the user submits/cancels in the app)
gallager edit /tmp/prompt.txt

# Claude projects (discovered from ~/.claude.json + additional folders)
gallager list-projects                     # name<TAB>path per line
gallager list-projects --json              # full info incl. last_used
gallager start-project ~/code/proj         # new session at project, runs `claude`
gallager start-project ~/code/proj -- --resume   # forwards `--resume` to claude
```

## Global options (available on every command)

| Option | Purpose |
|--------|---------|
| `--json` | Emit raw JSON-RPC response instead of formatted text |
| `--socket <path>` | Override socket path (otherwise uses `$GALLAGER_SOCKET`, then `$TMPDIR/gallager.sock`) |
| `--pane <id>` | Target a specific pane (e.g. `%3`) for input or splits |
| `--session <id>` | Target a specific session for window/session commands (`list-windows`, `new-window`, `set-title`, `set-color`, `set-emoji`, …) |
| `--window <id>` | Target a specific window for pane commands (`list-panes`, …) |

## Important details worth knowing

- **`send` sends text literally.** `gallager send "ls"` does *not* press Enter. Either pass `--enter` (`gallager send "ls" --enter`), use `$'ls\n'` in bash/zsh, or follow up with `gallager send-key enter`. `--enter` is shell-agnostic and avoids quoting tricks.
- **`new-session --if-missing` is idempotent.** Use it when a script needs *some* session called `--name` to exist without caring whether this run created it. The response includes `created: true|false` so you can branch on whether to populate panes.
- **`set-title` is session-only.** It writes to the `@gallager-description` tmux user option that Gallager's sidebar reads — the underlying tmux session/window names are untouched. The CLI only accepts `--session` (or defaults to the calling pane's session via `$TMUX_PANE`); there is no window/pane scope. Pass an empty string to clear. To rename the tab label of one window, use `gallager rename-window` instead.
- **`set-color` mirrors `set-title`** but writes the `@gallager-color` user option to render a small dot next to the session in the sidebar. Same session-only targeting rules. Valid names are `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `gray` (aliases: `violet`→purple, `magenta`→pink, `grey`→gray). Pass `none` or `""` to clear. The same flag also works at session creation: `gallager new-session --color blue`. Inside a `gallager apply` YAML, set `color: blue` at the top level for the same effect — re-applying the file syncs the color (clearing it when the field is removed).
- **`set-emoji` mirrors `set-title`** but writes the `@gallager-emoji` user option to render an emoji icon next to the session in the sidebar (in addition to or in place of the color dot). Same session-only targeting rules. The argument accepts either an emoji character (`"🚀"`, `"🐛"`) or a Unicode name / description (`rocket`, `bug`, `"smiling face heart"`); names are resolved locally via `Unicode.Scalar.Properties.name` — an exact match short-circuits to a single result, ambiguous queries print candidates and exit non-zero so the caller can be more specific. Input that's neither emoji nor a recognised name is rejected with a `validation` error. Pass `none` or `""` to clear.
- **`find-emoji <query>`** browses the Unicode emoji database without committing — prints `<glyph>  <name>` (one per line) for every match. Every whitespace-separated word in the query must appear in the candidate's name (case-insensitive); results are sorted shortest-name-first so the most canonical candidate floats to the top. `--json` emits `[{"emoji": "...", "name": "..."}, …]`; an empty match set is `[]` with exit 0 (success, no results) in JSON mode, exit 1 with a stderr message in human mode. Pure local lookup — never touches the relay/tmux.
- **`rename-window` is the only window-scoped CLI mutation.** Required arguments are the window ID (`session:index`) and the new name; both are positional. It calls `tmux rename-window`, which also disables tmux's automatic-rename for that window so the tab stops tracking the running command. Empty names are rejected.
- **`capture-pane` returns plain text**, not the JSON-RPC envelope. It's the same thing as `tmux capture-pane -p`; use `--scrollback` (`-S -`) to grab the full history when grepping.
- **`wait-ready` is the gate for scripts that auto-launch the app.** It polls `system.ping` until success or `--timeout` (default 30s) elapses; on timeout it writes the error to stderr and exits non-zero. Cheaper and more reliable than sleeping for a fixed time.
- **Context inference uses `$TMUX_PANE`.** When no `--pane`/`--window`/`--session` flag is given, the CLI fills in `pane_id` from `$TMUX_PANE` so commands operate on the *calling* pane (and its session/window) — not on whatever pane is globally active in tmux. If you run `gallager` from outside tmux there is no calling pane, so commands fall back to the active pane; pass `--pane`/`--window`/`--session` explicitly to be safe. `$TMUX_PANE` is tmux's own env var (set by tmux inside every pane), and its value is exactly the pane ID Gallager reports.
- **Socket resolution order**: `--socket` flag → `$GALLAGER_SOCKET` → `$TMPDIR/gallager.sock`. Inside Gallager-managed panes, `$GALLAGER_SOCKET` is set for you. Note: `$GALLAGER_SOCKET` is Gallager's JSON-RPC socket, separate from the tmux socket `tmux -S` uses.
- **`gallager edit` blocks.** It returns only after the user submits or cancels the prompt in the app. Great for interactive workflows, wrong for fire-and-forget scripts.
- **`notify` attaches pane context automatically** when `$TMUX_PANE` is set, so tapping the iOS notification jumps to the right pane.
- **`notify --push` mirrors the desktop banner to paired iOS devices.** Without `--push`, the notification only appears in macOS Notification Center; with `--push`, the host also sends an encrypted push payload through the relay server and (when the viewer is offline) APNs, exactly the same path Claude hook events use. Requires the host to have at least one paired viewer; without one the flag is a no-op (the local banner still shows). The pane context from `$TMUX_PANE` carries over so taps on the phone deep-link back to the originating pane.
- **`start-project` always runs `claude`.** Unlike `new-session --path`, which only auto-runs claude when the **Auto-run Claude in project folders** setting is on, `start-project` always launches the configured claude command in the new pane. Pass extra arguments after `--` to forward them (e.g. `start-project ~/code/foo -- --resume`).
- **`session-state` is a CLI override.** It flips the sidebar indicator (`working`, `idle`, `waiting`, `clear`) without changing the underlying tmux/Claude state — useful when scripting fake activity for demos or marking a manual workflow as needing attention. The override is wiped automatically when a Claude hook event for the same pane updates working/notification state, so live sessions revert to reality on their own. Target with `--pane` or `--session`; with neither flag it marks the calling pane (via `$TMUX_PANE`).
- **`set-progress` writes the same per-pane progress bar that `OSC 9;4` drives.** Accepted values are `0`–`100` (determinate blue bar), `indeterminate` (animated blue scanner), `warning` (yellow), `error` (red), and `clear`/`none`/`""` (clear). Targets the pane given by `--pane`, otherwise the calling pane via `$TMUX_PANE`. CLI updates and OSC sequences share `PaneState.progress`, so they override each other on a most-recent-write-wins basis — a script can set the bar before a long task and a subsequent `OSC 9;4` from the running program will reset it. Inside a `gallager apply` YAML, set `progress: 50` (or `progress: warning`, `progress: indeterminate`) on a pane to apply the same value at session-creation time; re-applying syncs the value (and clearing the field clears the bar).

## Composing with other tools

Pipe `--json` output into `jq` for scripting:

```bash
# Name of the currently active session
gallager current-session --json | jq -r '.result.name'

# IDs of every pane in the current window
gallager list-panes --json | jq -r '.result.panes[].id'

# Bail out if Gallager is not running
gallager ping --json >/dev/null 2>&1 || { echo "Gallager not running"; exit 1; }
```

Chain commands to script multi-step flows:

```bash
# Make a two-pane layout for build + logs
gallager new-window --path ~/code/proj
gallager split-pane right
gallager send $'tail -f /tmp/build.log\n' --pane %5
```

Mix `gallager` and `tmux` freely — the IDs are interchangeable:

```bash
# Use gallager to create, tmux to fine-tune, gallager to drive input
new_pane=$(gallager split-pane down --json | jq -r '.result.id')
tmux rename-window -t "$(gallager identify --json | jq -r '.result.window.id')" "build"
tmux resize-pane -t "$new_pane" -y 15
gallager send $'make test\n' --pane "$new_pane"
```

## Troubleshooting

- **`command not found: gallager`** — the CLI tool isn't installed. Tell the user to run **Gallager menu → Install Command Line Tool…**.
- **"socket connection failed"** — the Gallager app isn't running, or `$GALLAGER_SOCKET` points somewhere stale. Launch/focus the app and retry; `gallager ping` is the fastest check.
- **`Error: TMUX_PANE not set`** (from `edit`) — the command was run outside a tmux pane Gallager knows about. Run it inside a managed pane.
- **Unexpected `not_found` error** — the session/window/pane ID no longer exists. Re-list with `list-sessions` / `list-windows` / `list-panes` and retry with a fresh ID.

## Full API reference

For exhaustive details — every method's JSON-RPC payload, response shape, and error codes — see `references/api-reference.md`. Read it when the user asks about the wire protocol, wants to call the API directly (not through the CLI), or needs a response field that isn't mentioned above.
