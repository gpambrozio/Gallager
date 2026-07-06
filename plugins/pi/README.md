# pi plugin for Gallager

A Gallager **sidecar plugin** that teaches the Gallager (ClaudeSpy) Mac app to
monitor [pi](https://github.com/earendil-works/pi) — the `pi` AI coding assistant
CLI (`@earendil-works/pi-coding-agent`) — running in tmux panes: track
working / idle / done, raise the attention badge, fire a notification on turn
completion, and surface a per-session token / cost / latency / model meter via
OTLP telemetry. pi's projects are also listed in Gallager's "+" sidebar menu.

## Architecture

pi exposes a rich **extension event bus** (it has no config-based shell hooks), so
this plugin observes pi through a small pi extension. Two pieces:

```
 pi (Node)                           Gallager (Mac app)
 ┌──────────────────┐                ┌────────────────────────────────┐
 │ gallager.ts      │  ingress sock  │ IngressSocketServer            │
 │ (event bridge) ──┼───4-byte-LP───▶│   → SidecarPluginCore          │
 │   pi.on(...)     │  JSON frame    │     → translate_event RPC      │
 │   lifecycle      │                │        ┌─────────────────────┐ │
 │   + telemetry ───┼── OTLP POST ──▶│        │ bin/sidecar (Python)│ │
 └──────────────────┘  /v1/logs      │        │  event→PluginEvent  │ │
                                     │        └─────────────────────┘ │
                                     └────────────────────────────────┘
```

1. **`pi-extension/gallager.ts`** — a pi extension (auto-loaded from
   `~/.pi/agent/extensions/`). It subscribes to pi's event bus and forwards the
   lifecycle events Gallager cares about to Gallager's Unix-domain *ingress
   socket*, passing through `TMUX_PANE` (pane routing) and the project dir. It
   bakes in the socket path, plugin id, and OTLP endpoint at install time (pi
   does not inherit Gallager's env). It also POSTs one OTLP/JSON record per
   completed assistant message straight to Gallager's loopback receiver.
2. **`bin/sidecar`** — the long-lived Python process Gallager spawns. It maps pi
   events to Gallager's `AgentState`, installs/uninstalls the extension, launches
   pi in a fresh pane, and scans pi's session store for the project list.

## State mapping

Unlike agents that only emit an ambiguous "idle", pi's event bus is explicit, so
the mapping is direct — no state machine:

| pi event | forwarded frame | Gallager state | Attention badge |
|----------|-----------------|----------------|-----------------|
| `session_start` | `pi.session.start` | `idle` (session appears) | no |
| `agent_start` | `pi.agent.start` | `working` | no |
| `agent_end` | `pi.agent.end` (+ last-line summary) | `doneWorking` + notification | **yes** |
| `session_shutdown` (`reason: "quit"`) | `pi.session.shutdown` | session removed (`sessionEnded`) | — |
| `message_end` (assistant, w/ usage) | — (OTLP channel) | feeds the token/cost meter | — |

`session_shutdown` for `reason` `reload`/`new`/`resume`/`fork` is **not** an end —
pi immediately re-announces with a fresh `session_start`, so the sidecar ignores
those and only ends the pane's session on a real `quit`. On a session switch the
new session id re-stamps the pane's telemetry join key, resetting the meter like
`/clear` (same behavior as the built-in agents).

## Telemetry (token / cost / latency meter)

The manifest declares the OTLP namespace `pi` (`otlp.namespace`), which routes
`pi.api_request` log records into the per-session meter (issue #617). The
extension emits one record per completed pi assistant message, using Claude
Code's exact `api_request` attribute keys so the host aggregates them additively.
`session.id` is pi's own session UUID — the same id the sidecar reports in its
`PluginEvent`s, so the meter joins correctly. pi's reasoning tokens are folded
into `output_tokens` (Claude's convention).

## Install (development)

```bash
./scripts/dev-install.sh            # copy into ~/.gallager/plugins/pi (discoverable)
osascript -e 'quit app "Gallager"'  # relaunch Gallager from Applications
gallager plugin list                # → pi ... enabled ... folder
gallager plugin call pi install     # drop gallager.ts into ~/.pi/agent/extensions/
```

Then run `pi` inside a Gallager-managed pane — the session appears in the sidebar
and flips to the attention badge when a turn finishes. In Settings → Agents the
plugin also gets the generic launch / auto-run / close-pane-on-end controls, and
a per-project row installs the extension into `<project>/.pi/extensions/`.

> Folder-drop discovery skips symlinks (Gallager checks `isDirectory`, false for
> a symlink-to-dir), so `dev-install.sh` **copies**. Re-run it after editing
> `bin/sidecar` or `pi-extension/gallager.ts`, then relaunch Gallager.

## Testing

```bash
python3 tests/test_sidecar.py       # 23 tests: state mapping, install, project scan
```

The tests drive `bin/sidecar` as a real subprocess over its stdio JSON-RPC
transport. For an end-to-end check against real pi (no Gallager needed), point
the extension's `GALLAGER_INGRESS_SOCK` / `GALLAGER_OTLP_ENDPOINT` env fallbacks
at a local listener and run `pi -e pi-extension/gallager.ts --no-session -p "hi"`.

## Wire-format gotchas (the usual sidecar traps)

- **Three JSON casings:** `plugin.json` + the ingress socket frame are
  snake_case (`plugin_id`); the stdio RPC is camelCase (`pluginID`, `sessionID`,
  `tmuxPane`).
- **`appActions` is required** on every `PluginEvent` — omit it and the host
  silently drops the whole event. The sidecar always sends `"appActions": []`.
- **`sessionEnded`'s `sessionID` is the tmux PANE id**, not pi's session id (the
  host keys session-end by pane).
