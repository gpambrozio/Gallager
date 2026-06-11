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
- Guardian (auto-review) posture suppresses permission notifications AND forms — see below.

## Guardian (auto-review) posture (#585)

When Codex runs with `approvals_reviewer = "auto_review"` (legacy spelling
`guardian_subagent`) and an `on-request`/granular approval policy, tool approvals are
decided by Codex's guardian subagent, never the user: the `PermissionRequest` hook fires
*before* guardian routing, the guardian's outcome is a binary allow/deny with no TUI
prompt, and the next hook the core sees is `PostToolUse`. Surfacing the request would be
worse than noise — remote Approve/Deny is keystroke injection into a TUI prompt that
doesn't exist (it would type into the composer or Escape-interrupt the turn), and the
`awaitingPermission` state would linger for the whole tool runtime.

So `CodexTranslator.isGuardianHandled` suppresses **both the notification and the form**,
translating the event to plain `working`, when ALL of:
- the session's CODEX_HOME has reviewer `auto_review`/`guardian_subagent` (read fresh,
  see below);
- `permission_mode == "default"` — under `"bypassPermissions"` (policy `never`) guardian
  routing is off, so a hook firing at all means a REAL user prompt follows; a
  missing/unknown mode also fails safe to notifying;
- the tool is positively identified as guardian-reviewable (`isGuardianReviewable`):
  `Bash` (Codex serializes its whole shell family under this hook name) or
  `apply_patch`, plus the namespaced `mcp__…` family as future-proofing — verified
  against codex-rs, these are the only `tool_name`s its approval orchestrator emits.
  This **fails closed**, deliberately unlike the yolo path's fail-open
  `isYoloAutoApprovable`: an unknown or missing tool name notifies, so a future
  prompt-style tool can never be silently suppressed while a real TUI prompt waits.

**Fresh-read posture:** `CodexConfigReader` parses `approvals_reviewer` from the
session's root `config.toml` **on every permission request** — the events are rare and
human-paced, the file is tiny, and a fresh read means a TUI "Approve for me" toggle
(persisted to `config.toml` immediately) is honored by the very next event: no watcher,
no debounce window, no cache to go stale, and a CODEX_HOME created after launch just
works. The scanner is tolerant but every ambiguity degrades toward `user`
(notify-anyway): missing file/key, unknown values, unterminated quotes (torn writes),
and assignments hidden inside multi-line strings all read as `user`. Profile overrides
are honored in both spellings (`[profiles.<name>]` sections and dotted
`profiles.<name>.approvals_reviewer` keys); inline-table profiles are invisible (Codex
never writes them).

**Per-root attribution:** each event is attributed to its CODEX_HOME root (default +
`additional_config_folders`) via its `transcript_path` (the rollout lives under
`<CODEX_HOME>/sessions/`). Suppression requires positive attribution — no
`transcript_path`, or one under an untracked root, resolves to `user` so a
misattributed session can never eat a real prompt. Both sides of the prefix match are
symlink-resolved (`/var/…` vs `/private/var/…`).

**Unchanged:** ClaudeSpy's per-pane yolo toggle, the dispatcher auto-approve path, and
Claude Code's `PermissionRequest` handling.

**Known blind spots (v1):** per-invocation `-c approvals_reviewer=...` overrides and v2
`<name>.config.toml` profile overlay files aren't visible in `config.toml` (degrades to
notify-anyway when they enable guardian); MDM `allowed_approvals_reviewers` constraints
that force the effective reviewer away from the file value; hand-written
`approval_policy = "untrusted"`/`"on-failure"` combined with `auto_review` routes
approvals to the user but reads `permission_mode == "default"`, so ClaudeSpy would
wrongly suppress — no TUI preset can produce that combination (a future fix can read the
rollout's `turn_context.approval_policy` via the hook's `transcript_path`).

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
