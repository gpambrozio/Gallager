---
name: create-agent-plugin
description: Build a new Gallager sidecar plugin from scratch — a standalone executable that teaches the Gallager macOS app to monitor a coding agent (track session state, raise attention badges, fire notifications, push text into panes). Use this skill whenever someone wants to add support for a coding agent that Gallager doesn't already handle (anything beyond the built-in Claude Code and Codex), wire an agent's hooks into Gallager, write or debug a "sidecar plugin", build a Gallager plugin, or distribute one via URL. Trigger on phrases like "make a Gallager plugin for <agent>", "I want Gallager to track my <CLI/agent> sessions", "add <agent> support to Gallager", "write a sidecar plugin", "create an agent plugin", or "how do I get my agent's hooks into Gallager".
---

# Create a Gallager Agent (Sidecar) Plugin

A **sidecar plugin** is a standalone executable Gallager spawns as a child process
and talks to over stdin/stdout using JSON-RPC. It lets a third party add a brand-new
coding agent to Gallager — out of process, crash-isolated, no changes to the app.
Your plugin's job: turn your agent's hook events into the agent-blind `PluginEvent`
shape Gallager understands (session working / done / needs-attention, notifications,
project name), and optionally push text or keys back into the pane.

This skill ships a runnable Python starter and the full protocol contract. Lean on
them — don't hand-write the framing from memory.

## Two silent-drop traps to internalize first

Both make a plugin that "loads but does nothing", and neither logs an error
anywhere you'll see. Get these right before anything else.

**1. Three JSON places, two casings.** Gallager speaks JSON in three places:

- **`plugin.json` manifest** → snake_case (`schema_version`, `display_name`, `short_name`)
- **Ingress *socket* frame** (your hook → app) → snake_case (`plugin_id`, `context`, `payload`)
- **Stdio *transport* RPC** (app ↔ your sidecar) → **camelCase** (`pluginID`, `sessionID`, `tmuxPane`, `pluginRoot`)

So the `translate_event` params you read and the `PluginEvent` you write back over
stdio are **camelCase**. A `plugin_id` key in a `translate_event` reply is silently
dropped. (Reference §1.)

**2. `appActions` is required on every `PluginEvent`.** It is non-Optional in the
host and decoded with no default, so a `translate_event` reply or `emit_event` that
omits the `appActions` key **fails to decode and the whole event is silently
dropped** — the session never updates. Always send `"appActions": []` (or a
populated list). The template does this; don't remove it. (Reference §6.)

**Bonus trap (only if you send keystrokes):** a `TmuxKey` `.text` is
`{"text": {"_0": "abc"}}`, **not** `{"text": "abc"}`. Every enum value is a
`_0`-wrapped tagged object; a bare string fails to decode and the host drops the
*entire* `send_keys` array. (Reference §5a, §6's tagged-enum rule.) When unsure of
any wire shape, check `references/protocol-reference.md` — don't guess.

## Bundled resources

- **`assets/template/`** — copy these into the new plugin and edit:
  - `sidecar.py` — a complete, dependency-free sidecar. Handles framing, the RPC
    loop, and every method with safe defaults. The part you edit is marked `EDIT HERE`.
  - `hook.py` — the ingress bridge your agent's hooks invoke (only for hook-based agents).
  - `plugin.json` — a starter manifest.
- **`references/protocol-reference.md`** — the exhaustive contract: manifest schema,
  RPC vocabulary, every method's params/result shape, `PluginEvent`/`AgentState`/
  `AppAction` encodings, form request/response shapes, `TmuxKey`, spawn env, crash
  policy, distribution, settings, security. Read the relevant section when you need a
  precise shape; don't guess wire formats.

## Workflow

Work through these in order. Don't skip the test step — a sidecar has several moving
parts (framing, casing, routing) and "it loaded" is not "it works".

### Step 1 — Gather the essentials

Ask the user (or infer from their agent's docs) only what you actually need:

- **`id`** — lowercase `^[a-z0-9][a-z0-9._-]*$`, becomes the install directory name.
- **`display_name`** / **`short_name`** — sidebar label / pane badge.
- **How does the agent signal activity?** This decides the architecture:
  - *Shell hooks* (like Claude Code / Codex): the agent runs a script on events.
    You'll wire `hook.py` as a bridge and implement `translate_event`. **Most common.**
  - *Agent-native plugin / event bus*: some agents have **removed** shell hooks
    entirely. If yours has, the path is a small plugin (in the agent's own plugin
    format) that subscribes to its event bus and forwards frames to the ingress
    socket. First check whether your agent even *has* shell hooks.
  - *Process-only*: no events at all; Gallager just detects the agent's process in a
    pane. Set `process_names` and you may need little more than `initialize`.
  - **No start/exit event?** If the agent fires nothing on launch/quit (Gallager's
    process scan only re-detects on pane add/remove), have your bridge emit two
    *synthetic* events — one on start (→ `idle`, session appears) and one on graceful
    exit (→ an `appActions: [{"sessionEnded": …}]`, session removed). Reference §6a.
- **Does the agent have interactive prompts** (permission / questions)? If so you can
  surface them as forms via the `awaitingPermission` / `awaitingReplies` states and
  answer them back through `deliver_response` — by calling the agent's API, or by
  injecting keystrokes with `send_keys` if its only surface is a TUI. No capability
  needed. Reference §4a, §6.
- **What do the hook payloads look like?** Get a sample event JSON — you map its fields
  in `translate_event`. If the user doesn't have one, check the agent's hook docs.
- **Launch command** (optional) — how to start the agent in a fresh pane (for `command_for_launch`).
- **`process_names`** — the process base-name(s) for pane auto-detection (e.g. `["my-agent-cli"]`).

### Step 2 — Scaffold from the template

Create the plugin directory and copy the starter in. For development, build it
straight into the folder-drop location so testing is a restart away:

```bash
ID=my-agent
DIR=~/.gallager/plugins/$ID
mkdir -p "$DIR/bin"
cp <skill>/assets/template/sidecar.py "$DIR/bin/sidecar"   # keep the shebang
chmod +x "$DIR/bin/sidecar"
cp <skill>/assets/template/plugin.json "$DIR/plugin.json"
# hook-based agents also need the bridge:
cp <skill>/assets/template/hook.py "$DIR/hook.py"
```

(`<skill>` is this skill's own directory.) Then edit `plugin.json`: set `id`,
`display_name`, `short_name`, `version`, `process_names`, and `ui.color`. Keep
`runtime: "sidecar"` and `sidecar.executable: "bin/sidecar"`.

### Step 3 — Implement `translate_event` (the heart)

This is where the real work is — everything else has a working default. Open
`bin/sidecar` and rewrite the `EDIT HERE` block in `handle_translate_event` to map
the agent's hook payload onto:

- a **`sessionID`** — a stable id per agent session (derive from the payload; fall
  back to the pane id),
- a **`state`** — `state_working()`, `state_done(summary)`, or `state_idle()` (see
  the helpers in the file; full `AgentState` vocabulary in reference §6),
- and pass through **`tmuxPane`** (from `context["TMUX_PANE"]`) and **`projectPath`**.

Return the event for interesting hooks; respond `None` for events you want to ignore.
The returned event keeps `"appActions": []` (the template already includes it — leave
it). Add a `notification={"title":…, "body":…}` when the user should be pinged. Use
`log("info", …)` for diagnostics — never `print()` (stdout is the RPC channel).

### Step 4 — Get events flowing (wire the bridge)

For Gallager to receive anything, something in the agent's process must call the
ingress bridge on its events (reference §8). Which bridge depends on your agent:

- **Shell-hook agents:** use `hook.py`. Two ways to wire it:
  - *Manual (fastest to test):* register `hook.py` as a hook in the agent's own
    config now, so events start flowing. The bridge reads `GALLAGER_INGRESS_SOCK` and
    `GALLAGER_PLUGIN_ID` (Gallager sets these for the sidecar, but the agent's hook
    process won't have them — bake them in or rely on the defaults in `hook.py`).
  - *Automated:* implement the sidecar's `install` method to drop `hook.py` into the
    agent's config and register it, substituting those two env vars. This is what
    `gallager plugin install` / the Settings install button call. See reference §4, §8.
- **Agent-native-plugin agents (no shell hooks):** write a small bridge in the
  agent's own plugin format that subscribes to its event bus and forwards frames,
  with the socket path + plugin id baked in at install time (the agent process does
  not inherit Gallager's env). Your `install` drops it into the agent's plugin dir
  (honoring `configRoot` for per-project installs).

Edit `hook.py`'s `context` block to forward any extra env vars your `translate_event`
reads (project dir, etc.).

### Step 5 — Test with folder-drop

```bash
# 1. Confirm the binary runs and is executable
~/.gallager/plugins/$ID/bin/sidecar < /dev/null   # should exit cleanly on EOF

# 2. Restart Gallager (it discovers folder-dropped plugins at launch)
osascript -e 'quit app "Gallager"'   # then relaunch from Applications

# 3. Confirm it was discovered and spawned
gallager plugin list                 # your id should appear with source "folder"
gallager plugin info $ID
gallager plugin logs $ID             # your log() lines + any stderr

# 4. Fire a real event: trigger your agent inside a Gallager-managed pane so its
#    hook calls the bridge. The session should appear in the sidebar and flip to
#    "needs attention" on a done event.
```

If nothing shows up, work the chain in order: Is the process running
(`gallager plugin list`)? Any stderr (`gallager plugin logs $ID`)? Is the hook
actually firing (add a stderr line to `hook.py`)? Is `plugin_id` in the frame
snake_case and matching your id? Is the `translate_event` reply camelCase **and
does it include `appActions`** (omitting it silently drops the event)?

> Folder-drop discovery skips **symlinks** (it checks `isDirectory`, false for a
> symlink-to-dir), so a dev script must **copy** into `~/.gallager/plugins/<id>/`,
> not symlink — and re-copy after every edit, then relaunch.

### Step 6 — Distribute (when it works)

- **Folder-drop** is enough for personal use and sharing a zip a user unzips into
  `~/.gallager/plugins/`.
- **Remote install** (Settings → "Add Plugin from URL…" or `gallager plugin install <url>`):
  host `plugin.json` over HTTPS with `bundle_url` + `bundle_sha256` + `manifest_url`,
  and a zip whose root holds `plugin.json` and the executable. See reference §10 for
  the exact verify/unpack flow and §11 for the (honest) security model.

## Quick reference — what each RPC method is for

You implement the ones your agent needs; the template stubs the rest sensibly.

| Method | When you must care |
|--------|--------------------|
| `initialize` | Always — respond, and stash anything from the env you need |
| `translate_event` | Always — the core mapping (Step 3) |
| `command_for_launch` | If Gallager should be able to launch your agent in a pane |
| `install` / `uninstall` / `install_status` | If you automate hook wiring (Step 4). All receive `{configRoot}`: `null` = the default root, a path = a per-project install (reference §13) |
| `apply_settings` | If your plugin has user-tunable settings. A folder-dropped sidecar gets a generic Agents panel for free (`command_path`, `auto_run`, `close_pane_on_session_end`, …); stash the values and honor them. Reference §13 |
| `deliver_response` | If you emit `awaitingPermission`/`awaitingReplies` — receives the user's answer; act via the agent's API or `send_keys`. Reference §4a |
| `refresh_projects` | If you can enumerate the agent's projects for the "+" menu — push `set_projects`. Fired at startup and ~every 60s |
| `shutdown` | Always — flush and exit (template handles it) |
| `detect_pane` | Only if you opt into `rich_pane_detection` (richer than `process_names`) |

For exact params/results of any of these, and the `PluginEvent`/`AgentState` shapes,
read `references/protocol-reference.md`.
