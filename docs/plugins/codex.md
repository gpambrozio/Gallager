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
- `tool_input` decoding is tolerant (#717): MCP payloads carry the tool's RAW arguments
  (no `{server, tool, input}` wrapper), so `ClaudeCodeTool.decode` recovers server/tool
  from the `mcp__<server>__<tool>` name, and ANY surprising `tool_input` shape degrades
  to `.other` instead of failing the frame — a dropped `PermissionRequest` would be a
  real TUI prompt with no notification and no form.

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
- the session's EFFECTIVE reviewer is `auto_review`/`guardian_subagent` (live file value
  gated by the session's start snapshot — see below);
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

**Primary source — the rollout's `turn_context` (codex ≥ 0.146, #717):**
`CodexRolloutPostureReader` reads the LATEST `turn_context` record from the hook's
`transcript_path` on every permission request. codex ≥ 0.146 persists
`approvals_reviewer` + `approval_policy` into every `turn_context` record — written
when a turn spawns, from the same context that routes that turn's approvals — so this
is exact per-session ground truth. It resolves `.autoReview` only for
`auto_review`/`guardian_subagent` under the guardian-routing `on-request` policy
(`untrusted`/`on-failure` route approvals to the user even with `auto_review` set);
any other present value fails safe to `.user`. Crucially it survives **resumes**:
codex fires NO `SessionStart` hook for a resumed thread, and before #717 the snapshot
fallback below reconstructed from timestamps — permanently "ambiguous" for any thread
older than the last `config.toml` write — so every guardian-approved request of a
resumed session notified. It also attributes mid-session "Approve for me" toggles to
the toggling session (the fallback can only fail safe to notify-noise), lagging at
most one turn (a mid-TURN toggle shows up in the next turn's record).

**Fallback — fresh-read file gated by the session's start snapshot** (rollouts with
no `turn_context` reviewer signal, i.e. pre-0.146 codex or a missing/torn rollout):
`approvals_reviewer` is a GLOBAL file but a PER-SESSION runtime value. Codex loads
`config.toml` once at session start; a TUI "Approve for me" toggle sends
`override_turn_context` to the toggling session only while persisting the new value
globally (codex-rs `event_dispatch.rs`, `UpdateApprovalsReviewer`) — other live
sessions keep their start-time posture. So the core keeps a per-session **snapshot**,
captured from `config.toml` when the session's `SessionStart` hook arrives (the same
moment Codex loads it), and `CodexConfigReader` re-reads the file **on every permission
request** (rare, human-paced, tiny file — no watcher, no cache). Suppression requires
the fresh value AND the snapshot to agree on `auto_review`:

- agree on `auto_review` → suppress (single-session use, and every session started
  after the latest toggle);
- agree on `user` → notify;
- disagree → SOME session toggled and the toggler cannot be attributed → fail safe to
  notify. A still-`user` session can never have a real prompt eaten; the cost is
  notify-noise for still-guardian sessions until the file returns to their snapshot
  value (suppression self-heals) or they restart.

If the app launches mid-session (no `SessionStart` seen), the snapshot is
reconstructed from timestamps: `config.toml` unmodified since the session's rollout
file was created → the current value is what the session loaded; otherwise ambiguous →
notify. Session ends (the pane poll, or a `SessionEnd` hook if one ever appears) drop
the snapshot.

The scanner is tolerant but every ambiguity degrades toward `user`
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

**Permission-mode chip (#718):** the mode chip the UI renders is seeded from the hook
channel's Claude-compatible `permission_mode`, which encodes only the approval-POLICY
axis (`on-request` → `"default"`) — so under guardian posture it read "Default" while
every approval was being auto-decided. `CodexTranslator.effectivePermissionMode` folds
the resolved posture in: `"default"` + `.autoReview` → `"auto"` (the chip already
rendered as "Auto" for Claude); every other value passes through (`bypassPermissions`
keeps its loud chip, `nil` stays `nil`). To feed the per-tool events that carry a mode
without reading the rollout file per tool call, the core caches the last resolved
posture per session (`reviewerPostures`): `SessionStart` / `UserPromptSubmit` /
`PermissionRequest` resolve fresh (session birth, turn boundaries — so the chip heals
from a toggle with ≤ one turn of lag), `PreToolUse` / `PostToolUse` / `Stop` reuse the
cache.

**Unchanged:** ClaudeSpy's per-pane yolo toggle, the dispatcher auto-approve path, and
Claude Code's `PermissionRequest` handling.

**Known blind spots:** on codex ≥ 0.146 the turn_context read closes the former `-c
approvals_reviewer=...` override, profile-overlay, MDM-constraint, and hand-written
`untrusted`/`on-failure` + `auto_review` blind spots (they all materialize in the
turn's persisted context); what remains is the ≤ one-turn lag of a mid-TURN toggle
(the next request in the SAME turn still follows the previous record — for a toggle
ON that's transient notify-noise; codex applies overrides at next turn spawn, so the
record matches actual routing) and a future `granular` approval policy reading as
`.user` (notify-anyway) until its serialization is known. On pre-0.146 codex the v1
fallback blind spots still apply: `-c` overrides and v2 `<name>.config.toml` profile
overlays aren't visible in `config.toml` (degrades to notify-anyway when they enable
guardian); MDM `allowed_approvals_reviewers` constraints; `untrusted`/`on-failure` +
`auto_review` would wrongly suppress (no TUI preset produces that combination); a
toggle within the sub-second window between Codex loading `config.toml` and the
`SessionStart` hook arriving snapshots the post-toggle value.

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
