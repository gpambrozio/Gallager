# pi plugin for Gallager

A Gallager **sidecar plugin** that teaches the Gallager (ClaudeSpy) Mac app to
monitor [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
coding-agent sessions running in tmux panes: track working / done / idle, raise
the attention badge, fire notifications on turn completion, and surface a
per-session token / cost / latency / model meter via OTLP telemetry.

## Architecture

pi has a first-class **extension system** (TypeScript modules loaded via jiti
from `~/.pi/agent/extensions/`) with a rich lifecycle event bus, so this plugin
observes pi through an extension. Two pieces:

```
 pi (Node)                           Gallager (Mac app)
 ┌──────────────────┐                ┌────────────────────────────────┐
 │ gallager.ts      │  ingress sock  │ IngressSocketServer            │
 │ (event bridge) ──┼───4-byte-LP───▶│   → SidecarPluginCore          │
 │   subscribes to  │  JSON frame    │     → translate_event RPC      │
 │   session_start/ │                │        ┌─────────────────────┐ │
 │   agent_start/…  │                │        │ bin/sidecar (Python)│ │
 └────────┬─────────┘                │        │  frame→PluginEvent  │ │
          │ OTLP /v1/logs            │        └─────────────────────┘ │
          └──── (telemetry) ────────▶│ OTLPReceiver                   │
                                     └────────────────────────────────┘
```

1. **`pi-bridge/gallager.ts`** — a pi extension (auto-loaded from
   `~/.pi/agent/extensions/`, TypeScript, no compile step). It subscribes to
   pi's event bus and forwards compact frames to Gallager's Unix-domain
   *ingress socket*. It bakes in the socket path, plugin id, and OTLP endpoint
   at install time and passes through `TMUX_PANE` (routing) and the project dir.
2. **`bin/sidecar`** — the long-lived Python process Gallager spawns. It maps
   the bridge's frames to Gallager's `AgentState`.

Unlike opencode, **no synthetic lifecycle frames are needed**: pi fires real
events at both ends of a session's life (`session_start` on launch and on
`/new` / `/resume` / `/fork`; `session_shutdown` on quit — including Ctrl+C,
Ctrl+D, SIGHUP, and SIGTERM), and brackets every prompt with
`agent_start`/`agent_end`. That also means the sidecar needs no working/seen
state machine — the mapping is a pure function of the incoming frame.

## Event mapping

| pi event | → Gallager state |
|---|---|
| `session_start` (launch, `/new`, `/resume`, `/fork`, `/reload`) | `idle` (session appears / attention cleared) |
| `agent_start` (user prompt submitted) | `working` |
| `agent_end`, `stopReason: stop` | `doneWorking(summary)` + "Finished — <project>" notification |
| `agent_end`, `stopReason: error` | `doneWorking(errorMessage)` + error notification |
| `agent_end`, `stopReason: aborted` (Esc) | `doneWorking("Interrupted")` + notification |
| `session_shutdown`, `reason: quit` | `sessionEnded` (session removed) |
| `session_shutdown`, other reasons | ignored — a `session_start` follows immediately |

The `agent_end` summary is the last assistant message's visible text (trimmed to
300 chars by the bridge).

## Session lifecycle (start / exit)

- **Start** — pi emits `session_start` natively when a session starts, loads,
  or is replaced. The sidecar maps it to `idle`, so the session shows up in the
  sidebar (idle moon glyph + project name) before the first turn.
- **Session replacement** — `/new`, `/resume`, `/fork`, and `/reload` tear down
  the old session runtime (`session_shutdown` with that reason) and immediately
  start the next one (`session_start`). The sidecar ignores non-quit shutdowns —
  ending the Gallager session there would flicker the sidebar row — and the
  follow-up `session_start` re-stamps the same pane with the new pi session id.
- **Exit** — pi emits `session_shutdown` with `reason: "quit"` on Ctrl+C,
  Ctrl+D, SIGHUP, and SIGTERM. The bridge **awaits** the frame flush in its
  handler so the frame lands before the process dies, and the sidecar emits
  `AppAction.sessionEnded` keyed by the **pane id** (the host ends sessions by
  pane). `closePaneEligible` honors the `close_pane_on_session_end` setting
  (default off → the pane stays open). The one uncovered case is a **hard kill**
  (`SIGKILL`/crash): pi can't run handlers, so the stale session lingers until
  Gallager next reconciles.

pi runs tools without interactive permission gating (extensions can add gates,
but core pi has none), so this plugin never emits the `awaitingPermission` /
`awaitingReplies` form states.

## Telemetry (token / cost / latency meter)

pi sessions get the same per-session meter as Claude Code (issue #617). pi's
`message_end` event fires once per finalized message, and an assistant message
carries a complete `usage` block (tokens, cache, cost) plus provider/model — so
the bridge POSTs one OTLP/JSON log record per assistant message to Gallager's
loopback OTLP receiver (`/v1/logs`, plain `fetch`, fire-and-forget). Telemetry
never rides the ingress socket.

- The record's event name is `pi.api_request` and its attributes mirror
  Claude's `api_request` vocabulary exactly (`input_tokens`, `output_tokens` —
  pi already folds thinking output into `usage.output`, `cache_read_tokens`,
  `cache_creation_tokens`, `cost_usd` — pi computes cost itself, `duration_ms`
  = wall-clock `message_start`→`message_end`, `model`), so the manifest's
  `otlp` declaration (`{"namespace": "pi"}`) is all the host needs to
  aggregate it additively.
- **Join key:** `session.id` carries pi's session UUID
  (`ctx.sessionManager.getSessionId()`) — the same id the sidecar reports in
  every `PluginEvent`, which is what the host uses to stamp the pane's
  telemetry join key. The meter follows the pane's *active* pi session;
  `/new` / `/resume` reset the visible meter like Claude's `/clear` (the
  receiver keeps each session's running totals, so switching back restores
  them on the next completed message).
- **Endpoint baking:** the pi process doesn't inherit Gallager's env, so the
  sidecar substitutes `__GALLAGER_OTLP_ENDPOINT__` in the bridge at `install`
  time (from the `initialize` env's `otlpReceiverEndpoint` — the port the
  receiver *actually* bound that launch), exactly like the ingress socket path.
  Running the bridge straight from the repo falls back to the
  `GALLAGER_OTLP_ENDPOINT` env var for smoke tests. If no receiver was running
  at install, an empty endpoint is baked and telemetry stays off. Re-run
  **Install** after the fact (or after the receiver's port changes) to re-bake.

## Install (development)

```bash
./scripts/dev-install.sh          # copy into ~/.gallager/plugins/pi/
# restart Gallager, then in Settings enable the plugin and click Install
# (drops pi-bridge/gallager.ts into ~/.pi/agent/extensions/gallager.ts)
```

`gallager plugin list` should show `pi` (source `folder`). Start pi in a
Gallager-managed pane (`pi`) and drive a turn — the session appears in the
sidebar, flips to working while the model streams, and to "needs attention"
when the turn finishes.

## Projects in the "+" menu

pi projects appear in Gallager's sidebar "+" (new session) menu, the same as
Claude Code / Codex. pi keeps per-project session directories under
`~/.pi/agent/sessions/`; the directory name is a lossy munging of the cwd, but
every session file's **first line** is a `SessionHeader` carrying the exact
`cwd` — so the sidecar reads the newest `.jsonl`'s header per directory on
`refresh_projects` (fired at startup and every ~60s) and on `initialize`, and
emits `set_projects`. Projects whose directory no longer exists are filtered
out; `lastUsed` (the newest session file's mtime) drives recency sorting, and
duplicate cwds (e.g. from `--session-dir` experiments) keep the most recent.

## Settings (Agents tab)

The plugin uses Gallager's generic sidecar settings, so the Agents settings
panel works out of the box:

- **Command path** — optional override for the launch command. Empty → the
  sidecar launches bare `pi` (resolved on PATH). Delivered via `apply_settings`
  and used by `command_for_launch`.
- **Auto-run** — when off, `command_for_launch` returns null so Gallager doesn't
  auto-start pi in project panes.
- **Config Folders** — the default row is `~/.pi/agent` (declared via the
  manifest's `sidecar.default_config_root`); its **Install** writes the bridge
  to `~/.pi/agent/extensions/gallager.ts` (global — pi auto-discovers it for
  every project). Add a project folder to install the bridge into that
  project's `.pi/extensions/` instead (per-project install, honored via the
  `install` RPC's `configRoot`; pi loads project-local extensions only after
  the project is trusted).

## Test

```bash
python3 tests/test_sidecar.py     # 30 tests: mapping, lifecycle, install, projects, settings
```

For a live smoke test of the bridge without Gallager, load it explicitly and
point it at env-provided endpoints:

```bash
GALLAGER_INGRESS_SOCK=/tmp/test.sock pi -e pi-bridge/gallager.ts
```

## Debugging the bridge

Set `GALLAGER_PI_DEBUG=1` in the environment pi runs in. Every event the bridge
sees (and forwards) is logged to
`~/.gallager/state/plugins/pi/logs/bridge-debug.log` (override with
`GALLAGER_PI_DEBUG_LOG`). The sidecar's own stderr is at
`~/.gallager/state/plugins/pi/logs/stderr.log`.

## Layout

```
plugins/pi/
├── plugin.json                  # sidecar manifest (runtime: "sidecar")
├── bin/sidecar                  # Python sidecar (Gallager ↔ pi)
├── pi-bridge/gallager.ts        # pi extension (event bus → ingress bridge)
├── scripts/dev-install.sh       # folder-drop copy installer
├── tests/test_sidecar.py        # standalone sidecar tests
└── README.md
```

## Known limitations / follow-ups

- **Process detection**: pi runs as a Node script, so its `ps` comm is `node`,
  not `pi` — the manifest's `process_names: ["pi"]` won't match a running pi at
  Gallager startup. In practice this doesn't matter for live sessions (the
  bridge's `session_start`/`agent_start` frames stamp the pane), but a pi that
  was already sitting idle when Gallager launched stays undetected until its
  next event. `rich_pane_detection` could close this once the host wires it.
- A **hard kill** of pi (`SIGKILL`/crash) skips its shutdown handlers, so no
  `session_shutdown` frame is sent and the session lingers in the sidebar until
  Gallager next reconciles (graceful quit paths are covered).
- The baked OTLP endpoint goes stale if the receiver later binds a different
  port (re-run Install to re-bake).
- No `awaitingPermission`/`awaitingReplies` forms — core pi has no interactive
  gating to surface. If a popular pi extension adds permission prompts with a
  stable event surface, the bridge could forward those too.
- Event names confirmed against pi v0.80.3 (`@earendil-works/pi-coding-agent`).
- Formal E2E-suite integration: the Swift `macStageSidecarFixture` path only
  stages the bundled Swift `EchoPluginSidecar`, and a real-pi scenario would
  depend on live model calls (nondeterministic in CI) — so this plugin is
  covered by the standalone Python tests plus live verification instead. The
  host pipeline itself (ingress → `translate_event` → sidebar state /
  `sessionEnded`, and declared-namespace OTLP → meter) has E2E coverage via the
  echo fixture (`PluginSidecarIngressScenario`,
  `PluginSidecarSessionEndedScenario`, `PluginOTLPTelemetryScenario`).
