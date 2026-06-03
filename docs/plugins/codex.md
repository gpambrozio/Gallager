# Codex plugin — behavior spec

Normative per-event behavior for `CodexPluginCore` (spec §16). Mirrors the Claude
Code core; only the agent-specific differences are called out here. See
`docs/plugins/claude-code.md` for the shared mapping rationale.

- **Module:** `Sources/CodexPluginCore/`
- **Manifest:** id `codex`, display `Codex`, short `Codex`,
  `process_names: ["codex"]`, color `#3B82F6`.

## Settings (`settings.json`, snake_case)
| Key | Type | Default |
|---|---|---|
| `command_path` | String | `codex` |
| `auto_run` | Bool | `true` |
| `log_level` | enum | `info` |

## Project discovery
Scans `~/.codex/sessions/` (or `$CODEX_HOME/sessions/`) date-partitioned rollout
`.jsonl` files, extracting `cwd` + `started_at` defensively (trap-free), producing
`[AgentProject]` tagged `pluginID="codex"` (no `configDir`). An FSEvents watcher on
`~/.codex/sessions/` (debounced) drives `refreshProjects()`.

## Pane ↔ session correlation (core-internal, spec §12)
Codex keeps `~/.claudespy/codex-sessions/<tmux_pane>.json` (`{session_id, cwd,
started_at}`), written on a session-start event that carries a `TMUX_PANE`. When a
later frame omits the pane, the core resolves it by `session_id` from this store.
The app does not know about this file.

## Ingress bridge (install)
`install()` writes `codex-hook-bridge.py` into the plugin state dir and registers it
in `~/.codex/hooks.json` (Codex's `{matcher: ".*", hooks: [{type, command, timeout}]}`
shape) for Codex's event list (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PermissionRequest, PreCompact, PostCompact, SubagentStart, SubagentStop, Stop), baking
in `plugin_id=codex` + the socket path. The bridge harvests `cwd` from the payload
(Codex has no project-dir env var). This replaces the legacy
`codex plugin marketplace add` install flow (deleted in Phase B).

## Raw hook → `PluginEvent`
Codex routes through the same `HookAction.from` parse as Claude, so the mapping table is
identical to `docs/plugins/claude-code.md` (working/attention/notification/responseRequest/
appActions) — including the shared pre-parse subagent drop
(`CommonHookFields.droppableSubagentEventName`): Codex's bridge forwards
SubagentStart/SubagentStop, so the same `agent_id` filter applies here. With these
differences:
- The reused `HookEventMessage.buildNotification()` is fed `agent: .codex`, so notification
  copy reads "Codex …".
- `tmuxPane` is resolved via the frame, falling back to the correlation file by `session_id`.
- `contextProjectDir` comes from `CODEX_PROJECT_DIR` when present, else the payload `cwd`.

## Session end (no `SessionEnd` hook)
Codex CLI exposes no `SessionEnd` hook event (verified absent from the 0.136 binary;
its hook vocabulary is SessionStart, UserPromptSubmit, Pre/PostToolUse, PermissionRequest,
Pre/PostCompact, SubagentStart/Stop, Stop, Notification). So the core can't learn from a
hook when a session ends. Instead it runs a **process-exit monitor**: a ~5s poll
(`CodexPluginCore.pollSessionEnds`, macOS only) that asks the host which panes still run a
`codex` process (`PluginHost.agentPanes()` → `TmuxService.detectAgentPanes` scoped to the
plugin) and compares against the recorded sessions (`CodexSessionCorrelation.allPanes()`).
When a recorded pane's process has exited, the core `host.emit`s the same
`.sessionEnded(closePaneEligible: closePaneOnSessionEnd)` the hook path would have produced,
reusing the app's session-removal (row reverts to the terminal glyph) + yolo-reset +
poll/grace/`killPane` handling. The `ps`-walking
`agentPanes()` is only called while there are recorded sessions. On its first tick the
monitor reconciles correlation files left from a prior app run (process already gone) by
dropping them silently rather than reporting a stale end. Because an end is emitted only
once the process is genuinely gone, that *is* the clean-exit condition, so `closePaneEligible`
folds in the pref exactly as the hook path does.

## Response delivery
Identical keystroke mapping to Claude Code (`deliverResponse` → `sendText`/`sendKeys`,
including the AskUserQuestion arrow-navigation builder).

## Crash model (spec §13)
Rollout-file parsing MUST stay trap-free.
