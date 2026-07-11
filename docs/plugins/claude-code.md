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

**Premature-`Stop` suppression (Apple Intelligence, #644):** Claude can fire a `Stop`
while it is merely *paused* waiting on a background task or scheduled cron — the Stop
payload then carries a non-empty `background_tasks` / `session_crons` array
([hook docs](https://code.claude.com/docs/en/hooks#stop-input); modeled on `StopBody`
as presence-only `hasInFlightBackgroundWork`). Non-empty arrays alone don't prove
Claude is still running (a task may just be pending termination), so when the
per-agent **Verify completion with Apple Intelligence** setting is on
(`detect_false_stops`, default on) and such a Stop arrives, `handleIngress` runs
`last_assistant_message` through the on-device `StopCompletionClassifier`
(Foundation Models). A `.stillWaiting` verdict makes it emit a bare `.working` event
(no notification, no app action) so the spinner persists until Claude's *real* final
Stop (empty arrays) marks it done; a `.finished` verdict falls through to the normal
`.doneWorking`. The classifier returns `.finished` on any unavailability (macOS < 26,
Apple Intelligence off/not downloaded, inference error), so the worst case is the
pre-existing premature-Done — it can never strand a session. No safety-net timeout:
if the verdict is wrong and no further Stop arrives, the pane-scan idle detection
still recovers. The classify call runs inside the serial ingress FIFO, so a suppressed
Stop briefly stalls other sessions' hook processing (acceptable given its rarity).

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
