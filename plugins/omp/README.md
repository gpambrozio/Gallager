# omp plugin for Gallager

A Gallager **sidecar plugin** that teaches the Gallager (ClaudeSpy) Mac app to
monitor [omp](https://omp.sh) (oh-my-pi — can1357's coding-first fork of pi,
shipped as a native binary) sessions running in tmux panes: track working /
done / idle, surface tool-approval prompts as answerable forms, raise the
attention badge, fire notifications on turn completion, and surface a
per-session token / cost / latency / model meter via OTLP telemetry.

## Architecture

omp inherits pi's first-class **extension system** (TypeScript modules loaded
by omp's embedded Bun from `~/.omp/agent/extensions/`) with a rich lifecycle
event bus, so this plugin observes omp through an extension. Two pieces:

```
 omp (native binary, Bun)            Gallager (Mac app)
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

1. **`omp-bridge/gallager.ts`** — an omp extension (auto-loaded from
   `~/.omp/agent/extensions/`, TypeScript, no compile step). It subscribes to
   omp's event bus and forwards compact frames to Gallager's Unix-domain
   *ingress socket*. It bakes in the socket path, plugin id, and OTLP endpoint
   at install time and passes through `TMUX_PANE` (routing) and the project dir.
2. **`bin/sidecar`** — the long-lived Python process Gallager spawns. It maps
   the bridge's frames to Gallager's `AgentState` and answers approval forms by
   keystroke injection.

Like pi (and unlike opencode), **no synthetic lifecycle frames are needed**:
omp fires real events at both ends of a session's life. But the event
vocabulary diverged from pi in ways this plugin leans on (verified against omp
v17.1.8):

- `session_start` fires only on the **initial load** and carries no reason.
  Session replacement (`/new`, `/resume`, `/fork`, handoff, branch/tree jumps)
  fires its own `session_switch` / `session_branch` / `session_tree` events —
  the bridge re-labels those as `session_start` frames so the sidecar re-stamps
  the same pane with the new session id.
- `session_shutdown` means **process exit only** (Ctrl+C, Ctrl+D,
  SIGINT/SIGTERM, `/exit`) — so every shutdown ends the Gallager session, with
  no reason filtering. The handler **awaits** the frame flush so it lands
  before the process dies. A hard `SIGKILL` skips handlers; the stale session
  lingers until Gallager reconciles.
- `agent_end` carries `willContinue` when omp has already scheduled an
  automatic continuation (auto-retry, empty-stop retry). The bridge drops
  those, so no spurious "Finished" notification fires mid-turn.
- omp runs each `task` **subagent in-process with the same extensions
  re-bound** against a headless runtime. The bridge gates every handler on
  `ctx.hasUI` so N subagents can't flip the pane between working and done (the
  opencode issue #670 lesson — omp edition).

## Event mapping

| omp event | → Gallager state |
|---|---|
| `session_start` (also re-labeled `session_switch`/`branch`/`tree`) | `idle` (session appears / attention cleared) |
| `agent_start` (user prompt submitted) | `working` |
| `agent_end` (not `willContinue`), last `stopReason` normal | `doneWorking(summary)` + "Finished — <project>" notification |
| `agent_end`, `stopReason: error` | `doneWorking(errorMessage)` + error notification |
| `agent_end`, `stopReason: aborted` (Esc) | `doneWorking("Interrupted")` + notification |
| `tool_approval_requested` | `awaitingPermission` form (see below) |
| `tool_approval_resolved` | `working` (form cleared; the turn continues either way) |
| `session_shutdown` | `sessionEnded` (session removed, keyed by pane) |

The `agent_end` summary is the last assistant message's visible text (trimmed
to 300 chars by the bridge).

## Tool-approval forms

Unlike core pi, omp **has a tool-approval gate** (`tools.approvalMode:
always-ask | write | yolo`, default `yolo` — so prompts only appear when the
user opted in). When omp's TUI shows its Approve/Deny dialog, the bridge
forwards `tool_approval_requested` and the sidecar opens an
`awaitingPermission` form on the Mac/iOS viewer:

- The form's `requestID` is omp's `toolCallId` (stable per prompt).
- The approval event only carries the tool *name*, so the bridge captures each
  tool call's input at the `tool_call` interception event (which fires before
  the approval gate) and attaches a one-line description — the bash command,
  file path, or URL being approved — plus omp's safety-override `reason` when
  present (e.g. "Critical pattern detected").
- **Answers are keystrokes** injected into the pane (omp's dialog is a TUI
  select with Approve pre-selected): allow → `Enter`; deny → `Down`+`Enter`;
  deny-with-feedback additionally types the feedback into the editor
  afterwards, which omp delivers to the model as a steer message.
- `isAutoApprovable` stays `false`: omp only prompts when the user explicitly
  chose a non-yolo mode, so Gallager's yolo auto-approve must not override it.
- No "always allow" suggestion — omp's dialog has no such option.

If the user answers in the TUI instead, `tool_approval_resolved` clears the
form. Question (`ask`-tool) prompts and plan approvals have no extension event
surface in omp today, so no `awaitingReplies`/`awaitingPlanApproval` forms.

## Telemetry (token / cost / latency meter)

omp sessions get the same per-session meter as Claude Code (issue #617). omp's
`message_end` fires once per finalized message, and an assistant message
carries a complete `usage` block (tokens, cache, cost) plus model — the bridge
POSTs one OTLP/JSON log record per assistant message to Gallager's loopback
OTLP receiver (`/v1/logs`, plain `fetch`, fire-and-forget). Telemetry never
rides the ingress socket.

- Event name `omp.api_request`, attributes mirroring Claude's `api_request`
  vocabulary exactly (`input_tokens`, `output_tokens` — omp folds thinking
  output into `usage.output`, `cache_read_tokens`, `cache_creation_tokens`,
  `cost_usd` — omp computes cost itself, `duration_ms` — omp's own
  `message.duration`, falling back to a wall-clock `message_start`→
  `message_end` bracket, `model`), so the manifest's `otlp` declaration
  (`{"namespace": "omp"}`) is all the host needs.
- **Join key:** `session.id` carries omp's session UUID
  (`ctx.sessionManager.getSessionId()`) — the same id the sidecar reports in
  every `PluginEvent`. `/new` / `/resume` reset the visible meter like Claude's
  `/clear`.
- **Dedup:** by `message.id`, falling back to `responseId` (omp messages don't
  always carry an `id`).
- **Endpoint baking:** the omp process doesn't inherit Gallager's env, so the
  sidecar substitutes `__GALLAGER_OTLP_ENDPOINT__` in the bridge at `install`
  time (from the `initialize` env's `otlpReceiverEndpoint`). Running the
  bridge straight from the repo falls back to the `GALLAGER_OTLP_ENDPOINT` env
  var for smoke tests. Re-run **Install** if the receiver's port changes.
- Subagent usage is not metered: it would join on the subagent's session id
  (never stamped to the pane), so the `hasUI` gate drops it at the source.

## Install (development)

```bash
./scripts/dev-install.sh          # copy into ~/.gallager/plugins/omp/
# restart Gallager, then in Settings enable the plugin and click Install
# (drops omp-bridge/gallager.ts into ~/.omp/agent/extensions/gallager.ts)
```

`gallager plugin list` should show `omp` (source `folder`). Start omp in a
Gallager-managed pane (`omp`) and drive a turn — the session appears in the
sidebar, flips to working while the model streams, and to "needs attention"
when the turn finishes.

## Projects in the "+" menu

omp projects appear in Gallager's sidebar "+" (new session) menu. omp keeps
per-project session directories under `~/.omp/agent/sessions/`; the directory
name is a lossy munging of the cwd, but every session file carries a header
record (`type == "session"`) with the exact `cwd`. Unlike pi, the header is
usually the **second** line (a rewritable `title` record comes first), so the
sidecar scans the first few lines. Per-session artifact subdirectories (e.g.
`__advisor.jsonl`) are skipped by the non-recursive listing. `lastUsed` (the
newest session file's mtime) drives recency sorting; duplicate cwds keep the
most recent.

## Settings (Agents tab)

The plugin uses Gallager's generic sidecar settings:

- **Command path** — optional override for the launch command. Empty → bare
  `omp` (resolved on PATH).
- **Auto-run** — when off, `command_for_launch` returns null.
- **Config Folders** — the default row is `~/.omp/agent` (manifest
  `sidecar.default_config_root`); its **Install** writes the bridge to
  `~/.omp/agent/extensions/gallager.ts` (global — omp auto-discovers it for
  every project). Add a project folder to install into that project's
  `.omp/extensions/` instead.
- **Close pane on session end** — folded into `sessionEnded`'s
  `closePaneEligible`.

## Test

```bash
python3 tests/test_sidecar.py     # 39 tests: mapping, approval forms, keystrokes, install, projects, settings
```

For a live smoke test of the bridge without Gallager, load it explicitly and
point it at env-provided endpoints:

```bash
GALLAGER_INGRESS_SOCK=/tmp/test.sock omp -e omp-bridge/gallager.ts
```

## Debugging the bridge

Set `GALLAGER_OMP_DEBUG=1` in the environment omp runs in. Every event the
bridge sees (and forwards) is logged to
`~/.gallager/state/plugins/omp/logs/bridge-debug.log` (override with
`GALLAGER_OMP_DEBUG_LOG`). The sidecar's own stderr is at
`~/.gallager/state/plugins/omp/logs/stderr.log`.

## Layout

```
plugins/omp/
├── plugin.json                  # sidecar manifest (runtime: "sidecar")
├── bin/sidecar                  # Python sidecar (Gallager ↔ omp)
├── omp-bridge/gallager.ts       # omp extension (event bus → ingress bridge)
├── scripts/dev-install.sh       # folder-drop copy installer
├── tests/test_sidecar.py        # standalone sidecar tests
└── README.md
```

## Known limitations / follow-ups

- omp ships as a **native binary**, so `process_names: ["omp"]` actually
  matches live panes (unlike pi's `node` comm) — an omp already idle when
  Gallager launches is detected by the process scan.
- A **hard kill** (`SIGKILL`/crash) skips omp's shutdown handlers, so no
  `session_shutdown` frame is sent and the session lingers until Gallager next
  reconciles (graceful quit paths are covered).
- The baked OTLP endpoint goes stale if the receiver later binds a different
  port (re-run Install to re-bake).
- Approval keystrokes assume omp's default keybindings (`tui.select.*`:
  arrows + Enter). A user who re-bound those keys would need to answer in the
  TUI (the form still clears via `tool_approval_resolved`).
- `omp --profile <name>` keeps state under `~/.omp/profiles/<name>/agent/` —
  the install and project scan only cover the default profile.
- Event names and shapes confirmed against omp v17.1.8 (can1357/oh-my-pi).
- Covered by the standalone Python tests plus live verification; the host
  pipeline itself has E2E coverage via the echo fixture
  (`PluginSidecarIngressScenario`, `PluginSidecarSessionEndedScenario`,
  `PluginOTLPTelemetryScenario`).
