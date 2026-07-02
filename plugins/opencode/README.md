# opencode plugin for Gallager

A Gallager **sidecar plugin** that teaches the Gallager (ClaudeSpy) Mac app to
monitor [opencode](https://opencode.ai) sessions running in tmux panes: track
working / done / idle, raise the attention badge, fire notifications on turn
completion, render opencode's permission prompts as interactive Gallager/iOS
forms that answer back into opencode, and surface a per-session token / cost /
latency / model meter via OTLP telemetry.

## Architecture

opencode removed config-based shell hooks (the old `experimental.hook`), so this
plugin observes opencode through its **plugin system** instead. Two pieces:

```
 opencode (Bun)                      Gallager (Mac app)
 ┌──────────────────┐                ┌────────────────────────────────┐
 │ gallager.js      │  ingress sock  │ IngressSocketServer            │
 │ (event bridge) ──┼───4-byte-LP───▶│   → SidecarPluginCore          │
 │   subscribes to  │  JSON frame    │     → translate_event RPC      │
 │   the event bus  │                │        ┌─────────────────────┐ │
 │   + lifecycle    │                │        │ bin/sidecar (Python)│ │
 └──────────────────┘                │        │  event→PluginEvent  │ │
        ▲                            │        │  state machine      │ │
        │ send_keys (answer forms)   │        └─────────────────────┘ │
        └────────────────────────────┼──── deliver_response ──────────┘
                                     └────────────────────────────────┘
```

1. **`opencode-bridge/gallager.js`** — an opencode plugin (auto-loaded from
   `~/.config/opencode/plugin/`). Its `event` hook forwards the lifecycle events
   Gallager cares about to Gallager's Unix-domain *ingress socket*. It bakes in
   the socket path + plugin id at install time and passes through `TMUX_PANE`
   (routing), `serverUrl`, and the project dir. It also emits two *synthetic*
   frames opencode itself never fires: `gallager.lifecycle.started` when opencode
   loads it (≈ TUI start) and `gallager.lifecycle.stopped` from its `dispose` hook
   (≈ TUI quit) — see **Session lifecycle** below.
2. **`bin/sidecar`** — the long-lived Python process Gallager spawns. It maps
   opencode events to Gallager's `AgentState` and answers permission/question
   forms by injecting keystrokes into the pane (opencode's TUI has no reachable
   HTTP endpoint).

## Event mapping

| opencode event | → Gallager state |
|---|---|
| `gallager.lifecycle.started` (synthetic, on bridge load) | `idle` (session appears) |
| `session.status` `busy` / `retry` | `working` |
| `session.status` `idle` (after a turn) | `doneWorking` + notification |
| `session.status` `idle` (fresh session) | `idle` |
| `session.idle` (deprecated alias) | `doneWorking` (turn end) |
| `session.error` | `doneWorking(summary)` + notification |
| `permission.asked` / `permission.updated` | `awaitingPermission` (form) + notification |
| `permission.replied` | `working` (form cleared) |
| `question.asked` | `awaitingReplies` (form) + notification |
| `gallager.lifecycle.stopped` (synthetic, on `dispose`) | `sessionEnded` (session removed) |

The sidecar keeps a per-session `working`/`seen` flag so a turn-ending `idle`
becomes `doneWorking` (raising attention) while a brand-new session's first
`idle` stays `idle`, and a stray second `idle` never clears the attention badge.

## Session lifecycle (start / exit)

opencode fires **no event** when it launches into a fresh idle prompt, and none
when it quits — and Gallager's process scan only re-detects agents when a tmux
pane is *added or removed*, not when a process starts or dies inside a live pane.
So neither launching nor quitting opencode would update the sidebar on its own.
The bridge closes that gap with two synthetic frames (matching Claude Code's
`SessionStart` → idle / `SessionEnd` → session removed; no notifications):

- **Start** — the bridge's plugin factory runs once when opencode loads it
  (≈ TUI start), and forwards `gallager.lifecycle.started`. The sidecar maps it to
  `idle`, so the session shows up immediately (idle moon glyph + project name)
  before the first turn.
- **Exit** — the bridge registers opencode's `dispose` hook, which opencode runs
  as a shutdown finalizer on a graceful quit (the quit command, `/exit`, Ctrl-C).
  It forwards `gallager.lifecycle.stopped` (awaited so the frame flushes before the
  process dies). The sidecar emits `AppAction.sessionEnded` keyed by the **pane
  id**, so the host removes the session (the icon reverts to a plain terminal).
  `closePaneEligible` honors the `close_pane_on_session_end` setting (default off →
  the pane stays open). Verified against opencode v1.17.11 for both `/exit` and
  Ctrl-C. The one uncovered case is a **hard kill** (`SIGKILL`/crash): opencode
  skips finalizers, so no `stopped` frame is sent and the stale session lingers
  until Gallager next reconciles.

## Answering forms (permissions & questions)

opencode raises two interactive forms, both rendered by Gallager/iOS and answered
back by **keystroke injection** into the pane — the same mechanism the built-in
agents use. (opencode's TUI talks to its server over a unix socket and exposes no
reachable TCP HTTP endpoint, so the reported `serverUrl` can't be POSTed to; keys
are the transport-agnostic path. Verified against opencode v1.17.11.)

**Permission** (`permission.asked` → `awaitingPermission`) — a left/right list
"Allow once" / "Allow always" / "Reject":

| Gallager response | keystrokes |
|---|---|
| allow | `Enter` |
| allow + "Allow always" | `Right, Enter, Enter` |
| deny / deny-with-feedback | `Escape` (no inline feedback box for top-level sessions) |

**Question** (`question.asked` → `awaitingReplies`) — maps opencode's QuestionInfo
(`question`/`header`/`options`/`multiple`/`custom`) onto Gallager's
`AskUserQuestionRequest` (supports multiple questions + multi-select + free text).
Answered via opencode's TUI **number keys** (`1`-`9` jump to a row AND activate
it):

- **One single-select question** (no tabs): press the option's number → picks and
  submits. Free text → number of the "Type your own answer" row, type, `Enter`.
- **Multi-select / multiple questions** (tabbed, one tab per question + a Confirm
  tab): press the number of each selected option (multi-select **toggles**;
  single-select **picks** and auto-advances to the next tab), `Right` to advance a
  multi-select question, then `Enter` on the Confirm tab submits the whole set.

Verified against opencode v1.17.11's `question.tsx`. Edge cases left for follow-up:
questions with >9 rows (number keys only reach 9) and a model that pre-selects
options in its tool call (the sidecar assumes an empty initial selection).

## Telemetry (token / cost / latency meter)

opencode sessions get the same per-session meter as Claude Code — with **no
third-party plugin and no user-set `OPENCODE_*` env vars** (issue #617).
opencode has no usable native OTEL export, but the bridge already rides its
event bus: on every **completed assistant message** (`message.updated` with
`time.completed` set) it POSTs one OTLP/JSON log record to Gallager's loopback
OTLP receiver (`/v1/logs`, plain `fetch`, fire-and-forget, deduped by message
id). `message.updated` is never forwarded to the ingress socket — telemetry is
the OTLP channel, and the event fires on every streaming metadata change.

- The record's event name is `opencode.api_request` and its attributes mirror
  Claude's `api_request` vocabulary exactly (`input_tokens`, `output_tokens`
  with reasoning folded in, `cache_read_tokens`, `cache_creation_tokens`,
  `cost_usd` — opencode computes cost itself, `duration_ms` =
  `time.completed − time.created`, `model` = `modelID`), so the manifest's
  `otlp` declaration (`{"namespace": "opencode"}`) is all the host needs to
  aggregate it additively.
- **Join key:** `session.id` carries the tmux **pane id** (`TMUX_PANE`) — the
  same session identity the sidecar reports — so telemetry attaches to the pane
  with no host-side changes. Trade-off: multiple opencode sessions in one pane
  share one meter (Gallager treats the pane as "the session").
- **Endpoint baking:** the opencode process doesn't inherit Gallager's env, so
  the sidecar substitutes `__GALLAGER_OTLP_ENDPOINT__` in the bridge at
  `install` time (from the `initialize` env's `otlpReceiverEndpoint` — the port
  the receiver *actually* bound that launch), exactly like the ingress socket
  path. Running the bridge straight from the repo falls back to the
  `GALLAGER_OTLP_ENDPOINT` env var for smoke tests. If no receiver was running
  at install, an empty endpoint is baked and telemetry stays off. Re-run
  **Install** after the fact (or after the receiver's port changes) to re-bake.

## Install (development)

```bash
./scripts/dev-install.sh          # copy into ~/.gallager/plugins/opencode/
# restart Gallager, then in Settings enable the plugin and click Install
# (drops opencode-bridge/gallager.js into ~/.config/opencode/plugin/gallager.js)
```

`gallager plugin list` should show `opencode` (source `folder`). Start opencode
in a Gallager-managed pane (`opencode`) and drive a turn — the session appears
in the sidebar and flips to "needs attention" when the turn finishes.

## Projects in the "+" menu

opencode projects appear in Gallager's sidebar "+" (new session) menu, the same
as Claude Code / Codex. opencode stores its projects in a SQLite DB
(`~/.local/share/opencode/opencode.db`, respecting `XDG_DATA_HOME`); the sidecar
reads it read-only (`mode=ro`, WAL-aware — WAL readers never block the writer, so
it never perturbs a running opencode) on `refresh_projects` (fired at startup and
every ~60s) and on `initialize`, and emits `set_projects`. Projects whose
directory no longer exists are filtered out; `lastUsed` (from
`project.time_updated`) drives recency sorting.

opencode keys a project by its git **repo**, not folder, and records only the
first worktree it saw. A repo with multiple `git worktree`s would therefore show
just one — whichever opencode happened to record. The scan expands each stored
`worktree` into **every** worktree of its repo (`git worktree list --porcelain`),
so the main checkout and each linked worktree are individually launchable
(deduped across rows). The recorded worktree keeps opencode's own name; the
others are labeled by folder basename. Non-git dirs and a missing `git` fall back
to the stored path unchanged.

> Note: a *just-created* opencode project lives in the DB's WAL until opencode
> checkpoints it into the main `.db` file. `mode=ro` reads committed WAL frames so
> it surfaces right away; the scan only falls back to `immutable=1` (WAL-blind)
> when plain `mode=ro` can't open — a stale `-wal` with no `-shm` and no directory
> write access, i.e. opencode isn't running.

## Settings (Agents tab)

The plugin uses Gallager's generic sidecar settings, so the Agents settings panel
works out of the box:

- **Command path** — optional override for the launch command. Empty → the sidecar
  launches bare `opencode` (resolved on PATH). The value is delivered to the
  sidecar via `apply_settings` and used by `command_for_launch`.
- **Auto-run** — when off, `command_for_launch` returns null so Gallager doesn't
  auto-start opencode in project panes.
- **Config Folders** — the default row is `~/.config/opencode` (declared via the
  manifest's `sidecar.default_config_root`); its **Install** writes the bridge to
  `~/.config/opencode/plugin/gallager.js` (global). Add a project folder to install
  the bridge into that project's `.opencode/plugin/` instead (per-project install,
  honored via the `install` RPC's `configRoot`).

## Test

```bash
python3 tests/test_sidecar.py     # 36 tests: mapping, lifecycle, forms, install, telemetry, projects
node --check opencode-bridge/gallager.js
```

## Debugging the bridge

Set `GALLAGER_OPENCODE_DEBUG=1` in the environment opencode runs in. Every event
the bridge sees (and which it forwards) is logged to
`~/.gallager/state/plugins/opencode/logs/bridge-debug.log`
(override with `GALLAGER_OPENCODE_DEBUG_LOG`). The sidecar's own stderr is at
`~/.gallager/state/plugins/opencode/logs/stderr.log`.

## Layout

```
plugins/opencode/
├── plugin.json                  # sidecar manifest (runtime: "sidecar")
├── bin/sidecar                  # Python sidecar (Gallager ↔ opencode)
├── opencode-bridge/gallager.js  # opencode plugin (event → ingress bridge)
├── scripts/dev-install.sh       # folder-drop symlink/copy installer
├── tests/test_sidecar.py        # standalone sidecar tests
└── README.md
```

## Known limitations / follow-ups

- opencode has no plan-approval form, so `awaitingPlanApproval` is unused;
  permission prompts (`awaitingPermission`) and questions (`awaitingReplies`) are
  both interactive.
- A **hard kill** of opencode (`SIGKILL`/crash) skips its `dispose` finalizer, so
  no `gallager.lifecycle.stopped` frame is sent and the session lingers in the
  sidebar until Gallager next reconciles (graceful `/exit` and Ctrl-C are covered).
- Telemetry joins on the **pane id**, so multiple opencode sessions in one
  TUI/pane accumulate into a single meter (no reset on `session.created`); the
  baked OTLP endpoint goes stale if the receiver later binds a different port
  (re-run Install to re-bake).
- Live event names confirmed against opencode v1.17.11; the bridge forwards a
  broad allowlist (both `permission.asked` and the SDK-typed `permission.updated`)
  to stay correct across versions.
- Formal E2E-suite integration (the Swift `macStageSidecarFixture` path only
  stages the bundled Swift `EchoPluginSidecar`); this plugin is covered by the
  standalone Python tests instead. The declared-namespace telemetry pipeline
  itself (manifest `otlp` → receiver → meter) has E2E coverage via the echo
  fixture (`PluginOTLPTelemetryScenario`).
