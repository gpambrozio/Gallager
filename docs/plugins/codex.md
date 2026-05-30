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
appActions), with these differences:
- The reused `HookEventMessage.buildNotification()` is fed `agent: .codex`, so notification
  copy reads "Codex …".
- `tmuxPane` is resolved via the frame, falling back to the correlation file by `session_id`.
- `contextProjectDir` comes from `CODEX_PROJECT_DIR` when present, else the payload `cwd`.

## Response delivery
Identical keystroke mapping to Claude Code (`deliverResponse` → `sendText`/`sendKeys`,
including the AskUserQuestion arrow-navigation builder).

## Crash model (spec §13)
Rollout-file parsing MUST stay trap-free.
