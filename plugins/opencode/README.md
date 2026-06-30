# opencode plugin for Gallager

A Gallager **sidecar plugin** that teaches the Gallager (ClaudeSpy) Mac app to
monitor [opencode](https://opencode.ai) sessions running in tmux panes: track
working / done / idle, raise the attention badge, fire notifications on turn
completion, and render opencode's permission prompts as interactive
Gallager/iOS forms that answer back into opencode.

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
 └──────────────────┘                │        │ bin/sidecar (Python)│ │
        ▲                            │        │  event→PluginEvent  │ │
        │ HTTP reply                 │        │  state machine      │ │
        │ POST /permission/{id}/reply│        └─────────────────────┘ │
        └────────────────────────────┼──── deliver_response ──────────┘
                                     └────────────────────────────────┘
```

1. **`opencode-bridge/gallager.js`** — an opencode plugin (auto-loaded from
   `~/.config/opencode/plugin/`). Its `event` hook forwards the lifecycle events
   Gallager cares about to Gallager's Unix-domain *ingress socket*. It bakes in
   the socket path + plugin id at install time and passes through `TMUX_PANE`
   (routing), `serverUrl` (for answering permissions), and the project dir.
2. **`bin/sidecar`** — the long-lived Python process Gallager spawns. It maps
   opencode events to Gallager's `AgentState` and answers permission prompts via
   opencode's HTTP reply route (keystroke fallback when no server URL).

## Event mapping

| opencode event | → Gallager state |
|---|---|
| `session.status` `busy` / `retry` | `working` |
| `session.status` `idle` (after a turn) | `doneWorking` + notification |
| `session.status` `idle` (fresh session) | `idle` |
| `session.idle` (deprecated alias) | `doneWorking` (turn end) |
| `session.error` | `doneWorking(summary)` + notification |
| `permission.asked` / `permission.updated` | `awaitingPermission` (form) + notification |
| `permission.replied` | `working` (form cleared) |

The sidecar keeps a per-session `working`/`seen` flag so a turn-ending `idle`
becomes `doneWorking` (raising attention) while a brand-new session's first
`idle` stays `idle`, and a stray second `idle` never clears the attention badge.

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
reads it read-only (`immutable=1`, never perturbs a running opencode) on
`refresh_projects` (fired at startup and every ~60s) and on `initialize`, and
emits `set_projects`. Projects whose directory no longer exists are filtered out;
`lastUsed` (from `project.time_updated`) drives recency sorting.

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
python3 tests/test_sidecar.py     # 16 tests: mapping, forms, HTTP reply, install
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

- opencode has no plan-approval or multi-question form, so `awaitingPlanApproval`
  / `awaitingReplies` are unused; only permission prompts are interactive.
- opencode's OTLP namespace is `opencode.*`, which Gallager's telemetry
  accumulator doesn't parse yet (only `claude_code.*` / `codex.*`), so token/cost
  metering is out of scope.
- Live event names confirmed against opencode v1.17.11; the bridge forwards a
  broad allowlist (both `permission.asked` and the SDK-typed `permission.updated`)
  to stay correct across versions.
- Formal E2E-suite integration (the Swift `macStageSidecarFixture` path only
  stages the bundled Swift `EchoPluginSidecar`); this plugin is covered by the
  standalone Python tests instead.
