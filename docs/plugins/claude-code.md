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
  - `sessionEnd` (any reason) → `.sessionEnded(closePaneEligible: reason == .promptInputExit)`
    (resets the pane's yolo; close-eligible only on a clean prompt exit).

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
