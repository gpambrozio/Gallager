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

## The one gotcha to internalize first

Gallager speaks JSON in **three places with two different key casings**. Getting
this wrong is the #1 cause of a plugin that loads but does nothing:

- **`plugin.json` manifest** → snake_case (`schema_version`, `display_name`, `short_name`)
- **Ingress *socket* frame** (your hook → app) → snake_case (`plugin_id`, `context`, `payload`)
- **Stdio *transport* RPC** (app ↔ your sidecar) → **camelCase** (`pluginID`, `sessionID`, `tmuxPane`, `pluginRoot`)

So the `translate_event` params you read and the `PluginEvent` you write back over
stdio are **camelCase**. A `plugin_id` key in a `translate_event` reply is silently
dropped. When unsure, check `references/protocol-reference.md` §1.

## Bundled resources

- **`assets/template/`** — copy these into the new plugin and edit:
  - `sidecar.py` — a complete, dependency-free sidecar. Handles framing, the RPC
    loop, and every method with safe defaults. The part you edit is marked `EDIT HERE`.
  - `hook.py` — the ingress bridge your agent's hooks invoke (only for hook-based agents).
  - `plugin.json` — a starter manifest.
- **`references/protocol-reference.md`** — the exhaustive contract: manifest schema,
  RPC vocabulary, every method's params/result shape, `PluginEvent`/`AgentState`
  encodings, spawn env, crash policy, distribution, security. Read the relevant
  section when you need a precise shape; don't guess wire formats.

## Workflow

Work through these in order. Don't skip the test step — a sidecar has several moving
parts (framing, casing, routing) and "it loaded" is not "it works".

### Step 1 — Gather the essentials

Ask the user (or infer from their agent's docs) only what you actually need:

- **`id`** — lowercase `^[a-z0-9][a-z0-9._-]*$`, becomes the install directory name.
- **`display_name`** / **`short_name`** — sidebar label / pane badge.
- **How does the agent signal activity?** This decides the architecture:
  - *Hook-based* (like Claude Code / Codex): the agent runs a script on events. You'll
    wire `hook.py` as a bridge and implement `translate_event`. **Most common.**
  - *Process-only*: no hooks; Gallager just detects the agent's process in a pane.
    Set `process_names` and you may need little more than `initialize`.
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
Add a `notification={"title":…, "body":…}` when the user should be pinged. Use
`log("info", …)` for diagnostics — never `print()` (stdout is the RPC channel).

### Step 4 — Wire the agent's hooks (hook-based agents)

For Gallager to receive anything, the agent must call the ingress bridge on its
events. Two paths:

- **Manual (fastest to test):** register `hook.py` as a hook in the agent's own
  config now, so events start flowing. The bridge reads `GALLAGER_INGRESS_SOCK` and
  `GALLAGER_PLUGIN_ID` (Gallager sets these for the sidecar, but the agent's hook
  process won't have them — bake them in or rely on the defaults in `hook.py`).
- **Automated:** implement the sidecar's `install` method to drop `hook.py` into the
  agent's config and register it, substituting those two env vars. This is what
  `gallager plugin install` / the Settings install button call. See reference §4, §8.

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
snake_case and matching your id? Is the `translate_event` reply camelCase?

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
| `install` / `uninstall` / `install_status` | If you automate hook wiring (Step 4) |
| `apply_settings` | If your plugin has user-tunable settings |
| `shutdown` | Always — flush and exit (template handles it) |
| `detect_pane` | Only if you opt into `rich_pane_detection` (richer than `process_names`) |

For exact params/results of any of these, and the `PluginEvent`/`AgentState` shapes,
read `references/protocol-reference.md`.
