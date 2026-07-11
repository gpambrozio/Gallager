# Claude Code plugin — behavior spec

Normative per-event behavior for `ClaudeCodePluginCore` (spec §16: the per-event
behavioral contract lives in each core's doc, not the system spec). The system
spec stays agent-blind and only defines the `PluginEvent` fields this core
populates.

- **Module:** `Sources/ClaudeCodePluginCore/`
- **Manifest:** id `claude-code`, display `Claude Code`, short `Claude`,
  `process_names: ["claude"]`, color `#cb6f3a`.

## Settings (`settings.json`, snake_case)
| Key | Type | Default | Meaning |
|---|---|---|---|
| `command_path` | String | `claude` | binary used by `commandForLaunch` |
| `auto_run` | Bool | `true` | gates `commandForLaunch` |
| `log_level` | enum | `info` | log sink verbosity |
| `additional_config_folders` | [String] | `[]` | extra `.claude` roots to scan |

## Project discovery
Scans `~/.claude.json` + `~/.claude/projects/` (+ `additional_config_folders`),
defensively (trap-free), producing `[AgentProject]` tagged `pluginID="claude-code"`
with `configDir` set for non-default roots. An FSEvents watcher on
`~/.claude/projects/` (500 ms debounce) calls `refreshProjects()` → `host.setProjects`.

## Ingress bridge (install)
`install()` writes `claude-hook-bridge.py` into the plugin state dir and registers
it across Claude's hook events in `~/.claude/settings.json`, baking in
`plugin_id=claude-code` and the well-known socket `~/.gallager/state/ingress.sock`.
The bridge reads stdin + `TMUX_PANE` + `CLAUDE_PROJECT_DIR`, connects, writes one
length-prefixed `{plugin_id, context, payload}` frame, exits. Fires for any Claude
session (Gallager-launched or manual). `isInstalled`/`uninstall` manage that entry.

## Raw hook → `PluginEvent` (the 30→5 mapping)
Parsing reuses `HookAction.from(jsonData:)`. `sessionID` = the hook `session_id`;
`tmuxPane` = frame `TMUX_PANE`; `projectPath` = `CLAUDE_PROJECT_DIR` (fallback `cwd`).

**Subagent drop (shared, pre-parse):** `handleIngress` first drops any frame whose
payload carries an `agent_id` — a `Task` subagent's lifecycle event — *except*
`PermissionRequest` (a subagent's prompt still needs a user response). A trailing
`SubagentStop` fires seconds after the main `Stop`, and applying it would flip the
just-stopped session back to "Working". This filter is shared with Codex via
`CommonHookFields.droppableSubagentEventName(payload:)` so neither core can drift.
As defense-in-depth, `.subagentStart`/`.subagentStop` also map `isWorking` to `nil`,
so even a subagent event lacking an `agent_id` cannot drive the main session.

**Message-less `Stop` drop (translator):** subagents fire the plain `Stop` hook too,
not always with an `agent_id` for the pre-parse drop to see. Only main-agent stops
carry `last_assistant_message`, so a `Stop` without it is dropped entirely — applying
one would flip a mid-task session to doneWorking and fire a bogus notification.

**Paused-`Stop` drop (issue #644):** Claude also fires `Stop` when it *parks* the
turn waiting on background tasks / session crons to wake it back up. The payload's
`background_tasks`/`session_crons` arrays alone can't distinguish a pause from a
finish (a task pending termination lingers after a genuinely final message), so when
the arrays still hold pending work (task status not terminal; cron not
paused/disabled — `StopBody.pendingBackgroundWork`), `handleIngress` asks the
`StopFinalityClassifier` — Apple Intelligence's on-device model (FoundationModels,
macOS 26+) — whether `last_assistant_message` reads as final or as
waiting-for-background-work. Waiting → the frame is dropped (session stays
"Working", no notification); the real final `Stop` drives the state later. The
classifier fails open to "final" on every failure path (no SDK, pre-26 OS, model
unavailable/disabled, generation error, empty message), so the worst case is the
pre-#644 behavior — never a session stuck on "Working". In `--e2e-test` mode the
verdict is deterministic — a message containing `[e2e-still-waiting]` classifies as
still-waiting (CI has no Apple Intelligence) — exercised by the "Paused Stop
Ignored" scenario.

- **`working`** = `HookEvent.isWorking`: `true` entering the agent loop
  (userPromptSubmit, preToolUse, permissionRequest, …), `false` on `stop`/`stopFailure`,
  `nil` (no opinion) for neutral events.
- **`attention`** = `HookEvent.wouldTriggerNotification` (permissionRequest, stop,
  stopFailure, notification, AskUserQuestion).
- **`notification`** = `HookEventMessage.buildNotification()` copy (title/body), or none.
- **`responseRequest`** (requestID = `"<sessionID>:<eventName>"`):
  | Event | Form |
  |---|---|
  | `sessionStart` | `.prompt` |
  | `stop` | `.replyAfterStop(summary: lastAssistantMessage)` |
  | `permissionRequest` + tool `AskUserQuestion` | `.askUserQuestion` |
  | `permissionRequest` + tool `ExitPlanMode` | `.approvePlan` (allowsEdit false) |
  | `permissionRequest` (other) | `.permission` (isAutoApprovable = `isYoloAutoApprovable`; suggestions from `permission_suggestions`; allowsCustomInstructions) |
  | all other events | none |
- **`appActions`:**
  - `postToolUse` Write to `.md`/`.markdown` → `.openFileSuggestion(isPlan:)` (plan
    detection per the legacy `MarkdownOpenSuggestionStore`).
  - `userPromptSubmit` → `.dismissFileSuggestions`.
  - `sessionEnd` (any reason) → `.sessionEnded(closePaneEligible: reason == .promptInputExit)`.
    The app **removes the pane's `AgentSession`** (the row reverts from the idle moon
    glyph to a plain terminal — the legacy `claudeSession = nil`), resets the pane's
    yolo, and closes the pane only on a clean prompt exit. Note `sessionEnd` also maps
    `working == false`, but status fans out before app actions, so the removal wins —
    a `Stop` (also `working == false`) keeps the session alive and idle; only the
    `.sessionEnded` app action removes it.

Events producing none of the above are dropped (`handleIngress` returns `nil`).

## Response delivery (`deliverResponse` → keystrokes)
Ported from the former iOS response views:
- `.prompt(text)` / `.replyAfterStop(text)` non-empty → `sendText(text)` then `[.enter]`.
  Empty `replyAfterStop` (= "just interrupt") → `[.escape]`.
- `.permission(.allow, suggestionID)` → `[.text("1")]` (numbered suggestion when applied).
- `.permission(.deny, _)` → `[.escape]`.
- `.permission(.denyWithFeedback(t), _)` → `[.text("2")]` (or `"3"` when a suggestion is
  applied), then `sendText(t)`, then `[.enter]`.
- `.approvePlan(.approve, _)` → `[.text("3")]`; `.reject` → `[.escape]`.
- `.askUserQuestion(answers)` → arrow-key navigation built from the retained question
  params (the `AskUserQuestionKeystrokes` algorithm).

## Yolo
`PermissionRequest.isAutoApprovable` carries `PermissionRequestBody.isYoloAutoApprovable`.
The app (not this core) auto-approves when the pane is in yolo mode by calling
`deliverResponse(... .permission(decision: .allow, …))`. The core never knows about yolo.

## Crash model (spec §13)
Scanners parse hostile on-disk data and MUST stay trap-free (no force-unwrap on parsed
data; `do/try/catch` around decode; skip-and-log malformed entries).
