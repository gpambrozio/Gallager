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
| `select-session foo` / `close-session foo` | `tmux switch-client -t foo` / `tmux kill-session -t foo` |
| `list-windows [--session foo]` | `tmux list-windows [-t foo]` |
| `new-window` / `select-window foo:1` / `close-window foo:1` | `tmux new-window` / `tmux select-window -t foo:1` / `tmux kill-window -t foo:1` |
| `list-panes [--window foo:0]` | `tmux list-panes [-t foo:0]` (add `-a` for every pane on the server) |
| `split-pane right` | `tmux split-window -h` (horizontal = right; `-v` = down) |
| `select-pane %3` | `tmux select-pane -t %3` |
| `send "text" --pane %3` | `tmux send-keys -t %3 -l "text"` |
| `send-key enter --pane %3` | `tmux send-keys -t %3 Enter` |
| Pane field `command` / `cwd` | `tmux display -p -t %3 '#{pane_current_command}'` / `'#{pane_current_path}'` |

### When you must go straight to tmux

Examples of things `gallager` does not expose but tmux handles fine:

```bash
# Rename a window or session
tmux rename-window -t main:1 "logs"
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

Every command is one of: `list-*` (inspect), `new-*` / `split-pane` / `start-project` (create), `select-*` (focus), `close-*` (destroy), `send` / `send-key` (input), `notify` (alert), `edit` (block on prompt editor), or a utility (`ping`, `capabilities`, `identify`).

Commands default to the **current** session/window/pane (inferred from the calling shell's `$TMUX_PANE`). Override with `--session <id>`, `--window <id>`, or `--pane <id>` when targeting something else.

Append `--json` to any command to get raw JSON-RPC output suitable for `jq`. Use human-readable output when the user will read it directly; use `--json` when piping into other commands.

## Quick reference

```bash
# Sanity check
gallager ping                              # → "pong" if app is running
gallager identify                          # Show current session/window/pane
gallager capabilities                      # List every supported method

# Sessions
gallager list-sessions
gallager new-session --name work --path ~/code/proj
gallager select-session work
gallager current-session
gallager close-session work

# Windows (default to current session)
gallager list-windows
gallager list-windows --session work
gallager new-window                        # --session <id>, --path <dir>
gallager select-window main:1
gallager close-window main:1

# Panes (default to current window)
gallager list-panes
gallager split-pane right                  # left | right | up | down
gallager split-pane down --pane %3 --path ~/logs
gallager select-pane %3

# Input — `send` is raw (include \n yourself); `send-key` is named
gallager send $'make test\n'               # Bash: $'...' expands \n
gallager send "hello" --pane %5            # no newline sent
gallager send-key enter                    # enter|tab|escape|backspace|delete|up|down|left|right|space

# Notifications (tapping on iOS jumps back to the calling pane if $TMUX_PANE is set)
gallager notify --title "Build done" --body "All tests passed"
gallager notify --title "Alert" --subtitle "CI" --body "Tests failed on main"

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
| `--session <id>` | Target a specific session for window commands |
| `--window <id>` | Target a specific window for pane commands |

## Important details worth knowing

- **`send` sends text literally.** `gallager send "ls"` does *not* press Enter. Use `$'ls\n'` in bash/zsh, or follow up with `gallager send-key enter`.
- **Context inference uses `$TMUX_PANE`.** If you run `gallager` from outside tmux, session/window/pane context isn't known — pass it explicitly with `--pane`, `--window`, or `--session`. `$TMUX_PANE` is tmux's own env var (set by tmux inside every pane), and its value is exactly the pane ID Gallager reports — that's why the two stay in sync.
- **Socket resolution order**: `--socket` flag → `$GALLAGER_SOCKET` → `$TMPDIR/gallager.sock`. Inside Gallager-managed panes, `$GALLAGER_SOCKET` is set for you. Note: `$GALLAGER_SOCKET` is Gallager's JSON-RPC socket, separate from the tmux socket `tmux -S` uses.
- **`gallager edit` blocks.** It returns only after the user submits or cancels the prompt in the app. Great for interactive workflows, wrong for fire-and-forget scripts.
- **`notify` attaches pane context automatically** when `$TMUX_PANE` is set, so tapping the iOS notification jumps to the right pane.
- **`start-project` always runs `claude`.** Unlike `new-session --path`, which only auto-runs claude when the **Auto-run Claude in project folders** setting is on, `start-project` always launches the configured claude command in the new pane. Pass extra arguments after `--` to forward them (e.g. `start-project ~/code/foo -- --resume`).

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
