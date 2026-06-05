# Coding-Agent Plugin System

Status: Design — not yet implemented
Date: 2026-05-24
Author: Brainstormed with Claude

## 1. Goal

Replace the app's built-in support for specific coding agents (Claude Code, Codex) with a generic plugin system. Adding support for a new coding agent (OpenCode, Aider, Cline, anything future) must NOT require modifying the Gallager Mac app, the iOS app, or the relay server.

Concretely:
- A plugin owns everything agent-specific: project discovery, hook installation into the host agent's plugin system, raw-event translation, command-path resolution for auto-launch, notification copy, icons.
- The app owns everything agent-blind: window/pane mirror, tmux integration, plugin runtime + supervision, the `gallager` CLI surface, pairing, the relay path, the sidebar shell.
- The existing Claude Code and Codex code paths get extracted into bundled plugins that ship inside `Gallager.app`. They use the same plugin API every third-party plugin uses; nothing is privileged.

## 2. Background: how agent support is wired today

| Concern | Current implementation |
|---|---|
| Agent identity | `CodingAgent` enum in `ClaudeSpyNetworking/Models/CodingAgent.swift` — closed enum with two cases. |
| Hook ingestion | `HookServerService` runs a local HTTP server on `6111+<offset>`; agents POST JSON to `/api/hooks?project_path=…&tmux_pane=…`. A small `~/.claudespy-port` file tells bridge scripts the port. |
| Hook bridge | `plugin/gallager/scripts/hook.py` (Claude Code) and `plugin/codex/gallager/scripts/hook.py` (Codex) — read stdin, POST to localhost. |
| Hook installer | Claude: inline logic in `AppCoordinator` + bundled `plugin/.claude-plugin/marketplace.json`. Codex: `CodexPluginInstaller` Swift service + bundled `plugin/codex/.agents/plugins/marketplace.json`. Both register a Gallager-shipped marketplace with the host agent's CLI. |
| Project scanner | `ClaudeProjectScanner` reads `~/.claude.json` + `~/.claude/projects/*`. `CodexProjectScanner` walks `~/.codex/sessions/**` for rollouts. Both Swift services in `ClaudeSpyServerFeature/Services/`. |
| Pane detection | `TmuxService.detectClaudePanes()` walks each pane's process tree looking for descendants named `claude` or `codex`. Hardcoded. |
| Command path for auto-launch | `Settings.claudeCommandPath` and `Settings.codexCommandPath` — separate top-level settings. `AppCoordinator` switches on `CodingAgent` to pick which one. |
| Event vocabulary | `HookAction` enum (~30 cases) in `ClaudeSpyNetworking/Models/HookModels.swift`. Cases are Claude-Code-shaped; Codex maps onto a subset. Each case has its own `*Body` Codable struct. |
| Notification copy | `HookNotificationExtensions.swift` has hardcoded `"Claude Code"` strings; gradual agent-aware refactoring across the codebase. |

## 3. Design decisions (locked in during brainstorm)

| Decision | Choice |
|---|---|
| Scope | Full backend — plugins own scanner, installer, event interpretation, notification copy, icons, command resolution. App keeps the pane mirror, plugin runtime, `gallager` CLI surface, pairing & relay, sidebar shell. Plugins do NOT ship UI rendering schemas — there's no tool-card UI on either platform; the terminal mirror shows what's happening, and the rest of the agent's behavior surfaces through status/notification/response-request callbacks. |
| Runtime | Long-lived sidecar (LSP-style). One process per enabled plugin, spawned at app launch, supervised by Gallager. JSON-RPC over stdin/stdout (line-delimited `Content-Length:` framing + JSON body), both directions. |
| Distribution | In-app marketplace addressing plugins by manifest URL. Bundled plugins (Claude Code, Codex) ship inside the .app and are pre-registered with `bundle://` URLs through the same code path. |
| Trust | HTTPS-only manifest fetch + `bundle_sha256` pinning. First-run "Trust and Install" confirmation. No publisher signing in v1. |
| iOS rendering | iOS knows nothing about plugins, schemas, or template interpolation. The plugin system stops at the Mac boundary. iOS receives a thin wire format: session-status updates, a small closed enum of `AgentResponseRequest` shapes for interactive forms (permission, ask-user-question, prompt/reply), notifications with pre-baked title+body, a small per-plugin "presentation bundle" (icon + display name) for sidebar labelling, and the terminal stream (unchanged). Tool-card display on iOS is **removed** (it was debugging-only). |
| Event ingress (host agent → sidecar) | Each plugin owns its delivery mechanism. Gallager only specifies the contract: `~/.gallager/state/plugins/<id>/ingress.sock`, length-prefixed JSON frames. No queue, no fallback — if Gallager isn't running, events drop. |
| Wire compat | None. Bump `VersionCompatibility` minimum so v-new viewers refuse to pair with v-old hosts and vice versa. Drop all legacy event types; no dual-emit. |
| Rollout | Flag-day extraction. One PR/release lands: plugin runtime, extracted Claude Code plugin, extracted Codex plugin, marketplace UI, legacy types deleted, version bump. |

## 4. On-disk layout

```
Gallager.app/Contents/Resources/plugins/      ← bundled, immutable, ships with app
  claude-code/
    plugin.json                                ← manifest
    bin/sidecar                                ← Swift binary built from ClaudeCodePluginSidecar target
    agent-bundle/                              ← what sidecar.install() registers with the `claude` CLI
      .claude-plugin/marketplace.json
      gallager/
        hooks/hooks.json
        scripts/hook.py                        ← writes to ingress.sock
    ui/
      settings.json                            ← settings form schema (the only schema kept)
    assets/
      icon.png  icon@2x.png
  codex/                                       ← same shape

~/.gallager/plugins/                           ← user-installed, hot-swappable
  opencode/                                    ← same internal layout as bundled

~/.gallager/state/plugins/<id>/                ← per-plugin private state
  ingress.sock                                 ← Unix socket the sidecar listens on
  settings.json                                ← user settings for this plugin
  cache/  logs/  db/                           ← plugin scratch space

~/.gallager/registry.json                      ← canonical list of installed plugins
```

Bundled plugins are immutable on disk; users can disable but not uninstall them. They update only when the Gallager .app updates.

## 5. Plugin manifest

```json
{
  "schema_version": 1,
  "id": "claude-code",
  "display_name": "Claude Code",
  "short_name": "Claude",
  "version": "1.0.0",
  "publisher": "Anthropic",
  "manifest_url": "bundle://claude-code/plugin.json",
  "bundle_sha256": null,
  "runtime": "sidecar",
  "sidecar": {
    "executable": "bin/sidecar",
    "args": []
  },
  "capabilities": {
    "pushes_projects": true,
    "translate_event": true,
    "install": true,
    "detect_pane": true,
    "settings_schema": "ui/settings.json"
  },
  "process_names": ["claude"],
  "ui": {
    "icon": "assets/icon.png",
    "icon_ios": "assets/icon@2x.png"
  }
}
```

`bundle_sha256` is `null` for `bundle://` URLs (no download), required for `https://` URLs.

## 6. Sidecar protocol

JSON-RPC over the sidecar's stdin/stdout. Line-delimited LSP-style framing: `Content-Length:` header + blank line + JSON body. Both directions are full duplex.

### 6.1. App → Sidecar

| Method | When called | Returns |
|---|---|---|
| `initialize` | Once, immediately after spawn. App passes `{ plugin_root, state_dir, app_version }`. | `{ capabilities, schemas }` — sidecar advertises which methods it implements |
| `shutdown` | Before Gallager quits or disables the plugin (3s deadline before SIGTERM). | `null` |
| `refresh_projects` | Hint that the user explicitly asked for fresh project data (e.g., clicked the refresh button). Fire-and-forget — the sidecar SHOULD do a fresh scan and push via `set_projects`, but MAY ignore if its data is fresh enough. | `null` |
| `detect_pane` | Per tmux pane discovered (only if manifest declares `requires_rich_detection`). | `{ matches: true, project_path?, session_id? } \| { matches: false }` |
| `install` | User clicks "Install hooks" for this plugin. | `{ status, message }` |
| `uninstall` | User clicks "Remove hooks" or uninstalls the plugin. | `{ status, message }` |
| `is_installed` | Settings UI checks current state. | `bool` |
| `translate_event` | Per raw payload arriving on the ingress socket (or generated internally by the sidecar). | `PluginEvent` envelope |
| `deliver_response` | iOS user submitted an `AgentResponse` for a previously-emitted `AgentResponseRequest`. App passes `{ session_id, request_id, response: AgentResponse }`. Sidecar translates and drives delivery to the host agent (Section 7.5.1). | `null` |
| `get_settings_schema` | Settings UI opens this plugin's tab. | JSON schema for the form |
| `apply_settings` | User saves settings. | `{ status, message }` |
| `command_for_launch` | Gallager auto-starts the agent in a tmux pane for a project. | `{ command, env, args }` |
| `health` | Periodic heartbeat (30s). Three consecutive misses → considered crashed. | `{ ok: true }` |

Project listing is push-based: the app NEVER asks "what are your projects?" — the sidecar pushes its current list via `set_projects` whenever it has new data (see Section 6.2). On startup, the sidecar is expected to do an initial scan and send `set_projects` as soon as data is ready (typically a fraction of a second after `initialize` returns).

### 6.2. Sidecar → App (callbacks)

| Method | Purpose |
|---|---|
| `set_projects` | Replace the app's project list for this plugin with the supplied array `[ { id, name, path, last_used, agent_data } ]`. Sent whenever the sidecar's data changes. Full list, not incremental — simpler and the lists are small (tens, not thousands). |
| `emit_event` | Push a `PluginEvent` envelope into Gallager's session pipeline (used when the sidecar generates events without an incoming raw payload — e.g., filesystem watcher). |
| `send_text` | App writes `text` to the tmux pane backing `session_id` (verbatim, no special key processing). Sidecar uses this to deliver `PromptResponse`/`ReplyAfterStopResponse` text or free-text portions of `AskUserQuestionResponse`. |
| `send_keys` | App sends a key sequence (`[.down, .enter, .space, ...]`) to the pane backing `session_id`. Sidecar uses this to drive in-terminal UIs (Claude's AskUserQuestion menu, Codex's approval prompts, etc.). |
| `dismiss_response_request` | App removes the open response form on iOS for `request_id` (e.g., agent advanced on its own; sidecar wants to retract the request). |
| `request_notification` | Show a Mac notification + push to iOS. |
| `update_session_status` | Set working / attention / idle for a session. |
| `log` | Structured log line (level, message, context). Appended to per-plugin log file; surfaced in Settings → View Logs. |
| `prompt_user` | Ask Gallager to surface a modal (e.g., "Codex needs you to approve a trust prompt"). Rare. |

**Project refresh strategy is the sidecar's choice.** Each plugin picks whatever fits its host agent:

| Host agent's project model | Sidecar strategy |
|---|---|
| Claude Code (`~/.claude/projects/<encoded-cwd>/`) | Initial scan on startup; FSEvents watcher on `~/.claude/projects/`; debounced re-scan + `set_projects` on changes. No polling. |
| Codex (`~/.codex/sessions/YYYY/MM/DD/`) | Initial scan on startup; FSEvents watcher on `~/.codex/sessions/`; debounced re-scan + `set_projects` on new rollout files. No polling. |
| Hypothetical Aider with chat-history-in-cwd | FSEvents watcher across known parent dirs, or periodic re-scan if the file pattern is too broad to watch efficiently. |
| Hypothetical cloud-hosted agent with REST API | Periodic poll on a timer (sidecar picks the interval). Push via webhook/SSE if the agent supports it. |

The app neither knows nor cares which strategy a plugin uses. It just consumes `set_projects` and shows what arrives.

**Manual refresh button**: clicking it sends `refresh_projects` to every enabled sidecar. The sidecar treats this as a hint — typically does an immediate scan + `set_projects`, but a sidecar with very fresh data can no-op without sending a redundant update (the app's last received list stays correct).

**On sidecar crash/restart**: the supervisor restarts the sidecar; on re-initialize, the sidecar does a fresh scan and sends `set_projects`. The app keeps the previous list visible until fresh data arrives — stale data is better than an empty UI.

### 6.3. The `PluginEvent` envelope

What sidecars emit. The envelope is intentionally small — there is no structured "fields" payload, no event "kind" enum, no tool-card identifier. The terminal mirror shows the user what the agent is doing; the envelope just carries the state changes the app needs to react to.

```json
{
  "plugin_id": "claude-code",
  "session_id": "abc-123",
  "working": true,
  "attention": false,
  "notification": null,
  "response_request": null,
  "app_actions": []
}
```

- `working` (`bool` or `null`) and `attention` (`bool`) feed `AgentSession`'s status logic. Forwarded to iOS as `agent_session_status` (Section 7.4).
- `notification` (`NotificationSpec?`) — optional title + body the Mac should surface as a Mac notification AND forward to iOS as a push. Sidecar formats the strings; the app doesn't reshape them.
- `response_request` (`AgentResponseRequest?`) is set when the event needs user interaction on iOS. Closed-set shapes defined in Section 7.2.
- `app_actions` (`[AppAction]`, default `[]`) — discrete Mac-side feature triggers the sidecar wants to fire. Closed enum of app-known actions (full set in Section 17.1):
  - `openFileSuggestion(sessionId, path, displayName, isPlan)` — sidecar saw a Write to a `.md`/`.markdown` path; app surfaces an "open this file?" prompt.
  - `dismissFileSuggestions(sessionId)` — sidecar wants outstanding suggestions for this session cleared (typically on `userPromptSubmit`).
  - `closePaneIfPreferenceAllows(sessionId)` — sidecar signals the agent session ended cleanly; the app closes the tmux pane IFF the user has `closePaneOnSessionEnd` enabled.
  - New actions are added as a coordinated app + plugin change; the enum is intentionally small and agent-blind.

If a sidecar wants to react to something with no app-known outcome (e.g., internal logging), it just calls `log()` (Section 6.2) and doesn't emit a `PluginEvent` at all.

## 7. iOS surface

**iOS knows nothing about plugins, schemas, template interpolation, or the JSON-RPC protocol.** The plugin system stops at the Mac. iOS receives a small, app-defined wire format that's stable regardless of which plugins the Mac has loaded.

### 7.1. What iOS displays

| Surface | Source | Plugin-aware? |
|---|---|---|
| Terminal mirror | Existing `PaneStream` — already agent-blind. Unchanged. | No |
| Session list with per-session icon + name + working/attention badge | `AgentSession` + per-plugin **presentation bundle** (Section 7.3) | No — iOS just looks up the icon/name by `pluginID` |
| Interactive response forms (permission approval, ask-user-question, prompt input, stop reply) | `AgentResponseRequest` closed enum (Section 7.2) | No — closed shape on the wire |
| Notifications | Pre-baked `title` + `body` strings forwarded from the Mac | No |
| Project list | `AgentProject` with `pluginID` for sidebar icon lookup | No — same idea as session list |

What's **removed** from iOS: the per-`HookAction`-case display views (`EventRowView` and its supporting machinery). Those were added for debugging and aren't needed.

### 7.2. `AgentResponseRequest` — the closed-set response vocabulary

iOS keeps native SwiftUI forms for the small set of events where the user has to act. Plugin sidecars translate their agent-specific events into one of these shapes when forwarding to iOS. Anything outside this set stays Mac-only (no iOS form).

```swift
enum AgentResponseRequest: Codable, Sendable {
    // Free-text prompt input (today's PromptView).
    case prompt(PromptRequest)

    // Reply to the agent after it stops (today's StopResponseView).
    case replyAfterStop(ReplyAfterStopRequest)

    // Approve / deny an action, possibly applying a specific permission rule.
    case permission(PermissionRequest)

    // Pick from a structured list of options — possibly multiple questions in one prompt.
    // Today's AskUserQuestionResponseView.
    case askUserQuestion(AskUserQuestionRequest)

    // Approve / reject (and optionally edit) a multi-step plan. Today's ExitPlanModeResponseView.
    case approvePlan(ApprovePlanRequest)
}

struct PromptRequest: Codable, Sendable {
    let placeholder: String?       // "Send a message to Claude..."
}

struct ReplyAfterStopRequest: Codable, Sendable {
    let lastAssistantMessage: String?
}

struct PermissionRequest: Codable, Sendable {
    let toolName: String?           // "Bash", "Read", ...
    let description: String         // rendered to plain text BY THE SIDECAR; iOS just displays
    let suggestions: [PermissionSuggestion]
    let isAutoApprovable: Bool      // sidecar's judgment that this is safe for yolo mode
                                    // — when true AND user has yolo on for this pane, Mac
                                    // auto-approves without ever showing the iOS form.
                                    // Sidecar doesn't know about yolo; it just states safety.
}

struct PermissionSuggestion: Codable, Sendable {
    let id: String                  // sidecar-defined, opaque to iOS; round-trips back
    let label: String               // "Allow once", "Always allow", ...
    let badge: String?              // "ALWAYS", "THIS SESSION", ...
}

struct AskUserQuestionRequest: Codable, Sendable {
    let questions: [Question]       // a single prompt can carry multiple questions

    struct Question: Codable, Sendable {
        let prompt: String
        let options: [Option]
        let allowMultiple: Bool
        let allowFreeText: Bool     // shows an "Other" field iOS handles uniformly
    }

    struct Option: Codable, Sendable {
        let label: String
        let detail: String?         // optional descriptive subtitle
    }
}

struct ApprovePlanRequest: Codable, Sendable {
    let plan: String                // markdown allowed; iOS renders as text
    let allowEdit: Bool             // when true, the iOS UI exposes an editable text area
}
```

`description` and any other formatted strings are **rendered on the Mac by the sidecar**, not by iOS. iOS just displays. If a plugin wants agent-specific formatting (a custom render of a `Bash` command preview, plan markdown styled a specific way), it happens in the sidecar.

This closed set has to be expanded across both app and plugin versions if a new response shape is ever needed (e.g., a "pick-a-color" form). That's a deliberate constraint — plugin authors can't introduce arbitrary new iOS forms without a coordinated app update. Plugins for agents with unusual response types degrade gracefully: the iOS user sees no form for them; they're handled only on the Mac.

### 7.2.1. `AgentResponse` — what iOS sends back

Each `AgentResponseRequest` case has a paired response case. iOS sends the user's choices in structured form; the **plugin sidecar** is responsible for translating that into whatever its host agent expects (keystrokes, HTTP, MCP, etc.). iOS never builds Claude-specific keystrokes itself.

```swift
enum AgentResponse: Codable, Sendable {
    case prompt(PromptResponse)
    case replyAfterStop(ReplyAfterStopResponse)
    case permission(PermissionResponse)
    case askUserQuestion(AskUserQuestionResponse)
    case approvePlan(ApprovePlanResponse)
}

struct PromptResponse: Codable, Sendable {
    let text: String
}

struct ReplyAfterStopResponse: Codable, Sendable {
    let text: String                          // empty string = "send nothing, just interrupt"
}

struct PermissionResponse: Codable, Sendable {
    enum Decision: String, Codable, Sendable { case allow, deny }
    let decision: Decision
    let appliedSuggestionId: String?          // when user picked an "Always allow" / similar
}

struct AskUserQuestionResponse: Codable, Sendable {
    let answers: [QuestionAnswer]             // one per question, same order as the request

    struct QuestionAnswer: Codable, Sendable {
        let selectedOptionIndices: [Int]      // indices into the question's options
        let freeText: String?                 // set when the user typed an "Other" answer
    }
}

struct ApprovePlanResponse: Codable, Sendable {
    enum Decision: String, Codable, Sendable { case approve, reject }
    let decision: Decision
    let editedPlan: String?                   // present only if allowEdit was true AND user changed it
}
```

The wire shape from iOS back to the Mac is in Section 7.5; the sidecar-side delivery mechanism is in Section 7.5.1.

### 7.3. Per-plugin presentation bundle

Sent from the Mac to each newly-connected iOS viewer (and re-sent when a plugin is enabled/disabled or upgrades). Tiny — a few KB total.

```json
{
  "type": "plugin_presentations",
  "presentations": [
    {
      "id": "claude-code",
      "version": "1.0.0",
      "display_name": "Claude Code",
      "short_name": "Claude",
      "color": "#cb6f3a",
      "icon_b64": "<base64 PNG, usually <50 KB>"
    },
    { "id": "codex", ... }
  ]
}
```

iOS caches by `(plugin_id, version)`. Sessions and projects refer to plugins by id; iOS looks up icon/name/color from the cache.

### 7.4. Session status updates

The high-frequency wire format. Sent by the Mac whenever a session's status changes; iOS uses it to update sidebar badges.

```json
{
  "type": "agent_session_status",
  "session_id": "abc-123",
  "plugin_id": "claude-code",
  "working": true,
  "attention": false,
  "timestamp": "2026-05-24T18:32:11Z"
}
```

That's it — no fields, no tool name, no card. The terminal mirror tells the user what's happening visually; iOS doesn't need to duplicate that as structured text.

### 7.5. Response delivery wire format

A response request that needs iOS UI travels as its own message, separate from status updates:

```json
{
  "type": "agent_response_request",
  "session_id": "abc-123",
  "plugin_id": "claude-code",
  "request_id": "<uuid>",
  "request": <AgentResponseRequest>
}
```

When the user submits the form, iOS sends back over the existing command channel:

```json
{
  "type": "agent_response_submission",
  "session_id": "abc-123",
  "plugin_id": "claude-code",
  "request_id": "<uuid>",
  "response": <AgentResponse>
}
```

The Mac matches `request_id` to the originating `PluginEvent`, and calls `deliver_response(session_id, request_id, response)` on the owning sidecar (Section 6.1). The sidecar — and only the sidecar — decides how to convey that answer to its host agent (Section 7.5.1).

The Mac dismisses an outstanding response request on iOS by sending a follow-up message with the same `request_id` and a null `request` (e.g., when the user answers on the Mac side first, or the agent advances on its own). iOS treats that as "request fulfilled, hide the form."

### 7.5.1. How the sidecar delivers the response to the agent

The sidecar receives the structured `AgentResponse` via `deliver_response`. From there, the delivery mechanism is whatever the host agent supports. The plugin owns the translation — iOS knows nothing about it. Examples:

| Agent | What the sidecar does on receipt of `AgentResponse.askUserQuestion(answers)` |
|---|---|
| Claude Code | Looks up the original `AskUserQuestionRequest` it kept in state. For each question, derives the Claude-Code-specific keystroke sequence: down-arrows to navigate to the chosen option(s), space to multi-select, enter to advance, type-then-enter for the "Other" free-text. Calls back `send_keys(session_id, [.down, .down, .space, .enter, ...])` and `send_text(session_id, "custom answer")` (Section 6.2) to drive the tmux pane. |
| Codex | Similar key-sequence pattern, but codex's interactive UI may use different keys (e.g., `j`/`k` for nav). Sidecar emits the right keys for Codex. |
| Hypothetical HTTP-driven agent | Issues an HTTP POST to the agent's response endpoint with the structured answer — no key sequences at all. |
| Hypothetical MCP-driven agent | Sends an MCP message on its long-lived connection (opened during `initialize`). |

For the simpler response cases:
- `PromptResponse` / `ReplyAfterStopResponse` — typically just `send_text(session_id, response.text)` followed by `send_keys(session_id, [.enter])` for Claude/Codex. Other agents may do something different.
- `PermissionResponse` — Claude/Codex map to specific keys (e.g., `1` for allow, `2` for deny, suggestion-specific number); sidecar knows the mapping per agent version.
- `ApprovePlanResponse` — Claude/Codex equivalent of "approve" key + optional text injection for the edited plan.

The sidecar may want to keep some state per outstanding `request_id` (e.g., the original question text so it can decide keystroke navigation). That's the sidecar's responsibility — Gallager doesn't track it. When the sidecar emits a response request, it should remember whatever context it needs for the subsequent `deliver_response`.

### 7.6. What disappears from iOS

In `ClaudeSpyFeature/`:
- `Views/EventRowView.swift` — the per-event debug card. Deleted.
- The `extension HookEvent.responseView(...)` in `EventResponseView.swift` — replaced by a `switch` over `AgentResponseRequest` cases.
- Any iOS code that decodes `HookAction` / `HookEvent` / their `*Body` types — those types are gone from `ClaudeSpyNetworking` entirely.
- `Views/ResponseViews/AskUserQuestionKeystrokes.swift` (the `KeystrokeBuilder` + Claude-specific navigation logic) — deleted. iOS no longer constructs agent-specific keystrokes; it sends a structured `AskUserQuestionResponse` and the sidecar handles delivery.
- Per-tool-name decoding logic in iOS (it gets `description` as a plain string from the Mac).
- Any iOS-side dependency on `TmuxKey` / keystroke shapes for driving the agent's interactive UIs — that's the sidecar's job now.

What stays in `ClaudeSpyFeature/`:
- All five `ResponseViews/` files (`PromptView`, `StopResponseView`, `PermissionRequestResponseView`, `AskUserQuestionResponseView`, `ExitPlanModeResponseView`) — they keep their UI, just driven by `AgentResponseRequest` cases instead of `HookAction` cases. On submit, they emit an `AgentResponse` envelope (Section 7.5) — no keystroke construction.
- `SessionListView`, `LiveTerminalView`, `InteractiveTerminalView`, etc. — unchanged behavior, just sourced from `AgentSession` with `pluginID` instead of `agent: CodingAgent`.

## 8. Hook ingress

The contract Gallager imposes: the sidecar listens on `~/.gallager/state/plugins/<id>/ingress.sock`, length-prefixed JSON frames, one frame per raw payload. How payloads arrive there is entirely the plugin's responsibility.

If Gallager isn't running, the sidecar isn't running, the socket doesn't exist. Events that fire are dropped silently. No queue, no fallback. (Gallager observes sessions that happen while it's open; it isn't a retroactive monitor.)

Different agents have different IPC affordances; the plugin matches the host agent:

| Host agent integration model | What the Gallager plugin ships |
|---|---|
| Hook-based, command type (Claude Code, Codex) | A `bridge/hook` script (any language) registered in the agent's hook config. Script reads stdin, opens `ingress.sock`, writes one frame, exits. |
| Hook-based, prompt or HTTP type | Config entry pointing at an HTTP endpoint the sidecar itself hosts (sidecar handles ingress internally). |
| Streaming JSON firehose (e.g., `codex exec --json`) | Sidecar spawns/attaches to the agent's stream; no bridge script. |
| Transcript file on disk | Sidecar runs FSEvents on the transcript, tails it, parses appends. |
| Long-lived RPC (MCP, gRPC) | Sidecar opens the connection at startup and keeps it. |

Socket frame format: 4-byte big-endian length + JSON body `{ "context": { env vars }, "payload": <raw> }`.

Backpressure & error handling:
- **Sidecar slow to read:** writes from the bridge script block. If the sidecar wedges, the bridge script's host-agent-imposed timeout (e.g., Claude Code's hook timeout, Codex's `timeout` field) fires and the host agent moves on. The bridge script just exits non-zero; Gallager doesn't see the dropped event. Acceptable.
- **Sidecar fails to parse a frame:** log the parse error to the sidecar's log file, drop that one frame, keep the socket alive for the next frame. Don't crash the sidecar over malformed input.
- **Socket disappears mid-write (sidecar crashed):** bridge script gets a write error; exits non-zero. Event is dropped. Gallager's supervisor restarts the sidecar per Section 12's crash policy.

## 9. Distribution & installation

### 9.1. Registry

`~/.gallager/registry.json` is the canonical list. Bundled plugins appear here with `source: "bundled"` and `manifest_url: "bundle://<id>/plugin.json"`; user installs appear with `source: "url"` and the original URL.

### 9.2. Install flow (third-party)

1. User: Settings → Plugins → **Add Plugin from URL…**, pastes `https://opencode.ai/plugins/gallager.json`.
2. `HTTPS GET` manifest. Validate it's well-formed and `schema_version` matches.
3. Show a confirmation sheet with display name, publisher, version, source URL, bundle size + sha256, and an explicit "This plugin will run arbitrary code on your Mac" warning. Buttons: `Cancel` / `Trust and Install`.
4. On confirm, `HTTPS GET` `bundle_url` into a temp file. Verify `sha256` against the manifest. Mismatch → abort with a specific error.
5. Unpack zip into `~/.gallager/plugins/<id>.installing/`. Validate tree (manifest at root, `bin/sidecar` exists and is executable, declared assets present).
6. Atomic rename `<id>.installing/` → `<id>/` (replacing any existing `<id>/` via a `.replacing/` swap).
7. Append entry to `registry.json` via temp + rename.
8. Spawn the sidecar via `SidecarSupervisor`. Call `initialize`. On failure, mark plugin disabled with the error message; leave files in place so the user can retry.

### 9.3. Update flow

On Gallager launch (and manual "Check for updates"):
- For each `source: "url"` plugin: `HTTPS GET` the manifest with `If-None-Match` / `If-Modified-Since`.
- If new version > installed: surface a "Updates available" badge in Settings. **Never auto-install.**
- User clicks "Update" → same flow as install. Trust prompt is skipped (already trusted at the same manifest URL).
- If `bundle_url`'s host changes between updates, the trust prompt re-appears with a "Source changed" warning.

### 9.4. Uninstall flow

1. Confirm "Remove OpenCode and all its data?"
2. `sidecar.uninstall()` RPC (best-effort; failures logged but don't block).
3. `sidecar.shutdown()`. Supervisor SIGTERMs then SIGKILLs after 5s.
4. Delete `~/.gallager/plugins/<id>/`.
5. Prompt: also delete `~/.gallager/state/plugins/<id>/`? Default yes.
6. Remove from `registry.json`.

Bundled plugins cannot be uninstalled. They CAN be disabled — sidecar stops, registry entry stays, hooks remain in the host agent's config (re-enabling restores).

### 9.5. iOS

iOS doesn't install or know about plugins. It consumes whatever the paired Mac forwards via `plugin_presentations` (Section 7.3). Multiple paired Macs may have different plugin sets; iOS shows the union, events are tagged with their originating Mac (existing behavior).

## 10. Extracting Claude Code + Codex

### 10.1. New Swift packages in `ClaudeSpyPackage/Sources/`

```
GallagerPluginProtocol/        Codable JSON-RPC envelope, PluginEvent, manifest structs (Mac-only)
ClaudeCodePluginCore/          Claude Code logic (scanner, installer, event translator, command resolver)
CodexPluginCore/               Codex logic (scanner, installer, event translator, command resolver)
ClaudeCodePluginSidecar/       executable target wrapping Core in JSON-RPC stdin/stdout server
CodexPluginSidecar/            executable target wrapping Core in JSON-RPC stdin/stdout server
ClaudeSpyPluginRuntime/        Mac-only. PluginRegistry, SidecarSupervisor, PluginRouter,
                               IngressBroker, AssetCache, PluginEventDispatcher (routes
                               PluginEvent envelopes into status/notification/response/app-action
                               sinks)
```

No shared-with-iOS plugin module. `AgentResponseRequest`, `AgentSessionStatusUpdate`, and `PluginPresentation` types live in `ClaudeSpyNetworking` (which already crosses Mac/iOS); everything plugin-runtime-specific is Mac-only.

An Xcode build phase copies the two sidecar binaries + their manifests + assets into `Gallager.app/Contents/Resources/plugins/<id>/`.

### 10.2. Code that moves out of the app

| Today | Destination |
|---|---|
| `ClaudeProjectScanner.swift` | `ClaudeCodePluginCore`. Wrapped in an FSEvents-driven loop in `ClaudeCodePluginSidecar`: initial scan on `initialize`, watcher on `~/.claude/projects/`, debounced re-scan + `set_projects` callback on changes. |
| `CodexProjectScanner.swift` | `CodexPluginCore`. Same pattern as Claude — initial scan + FSEvents watcher on `~/.codex/sessions/`. |
| `CodexPluginInstaller.swift` | `CodexPluginCore`; invoked by sidecar's `install`/`uninstall`/`is_installed`. |
| `ClaudeBinaryLocator.swift` | `ClaudeCodePluginCore`; used by `command_for_launch`. |
| (inline Claude install logic in `AppCoordinator`) | `ClaudeCodePluginCore`. |
| `ClaudeCodeTools.swift` (in `ClaudeSpyNetworking/Models/`) | `ClaudeCodePluginCore` (it's Claude-specific; the app never needed it outside event decoding). |

### 10.3. Code that disappears from the app entirely

(See Section 7.6 for the iOS-side deletions in `ClaudeSpyFeature/`; the items below are app-wide / shared / Mac.)

- `HookServerService.swift` — the local HTTP server. `~/.claudespy-port` goes with it.
- `HookEvent`, `HookAction`, every `*Body` Codable struct (`SessionStartBody`, `PreToolUseBody`, ...), `CommonHookFields`, `SetupTrigger`, `SessionEndReason`, all `PermissionSuggestion*` helpers. From both `ClaudeSpyNetworking/Models/HookModels.swift` and `ClaudeSpyServerFeature/Hooks/HookModels.swift`.
- `CodingAgent` enum.
- `Settings.claudeCommandPath` and `Settings.codexCommandPath` top-level keys (after one-shot migration into per-plugin settings).
- All `case .claudeCode:` / `case .codex:` switches across `AppCoordinator`, `Settings`, `MainView`, `MainViewComponents/NewSessionContent`, `TmuxService`.
- `plugin/gallager/` and `plugin/codex/` folders at the repo root (they relocate into `Resources/plugins/<id>/agent-bundle/` inside the package).
- `HookNotificationExtensions.swift` hardcoded "Claude Code" strings — replaced by templates that interpolate `plugin.display_name`.

### 10.4. Renames (deferred from the Codex plan; now appropriate)

| Today | Becomes |
|---|---|
| `ClaudeSession` (`ClaudeSpyNetworking/Models/HookModels.swift`) | `AgentSession`. `agent: CodingAgent` → `pluginID: String`. Status (`isWorking`/`needsAttention`) tracked directly on the session as plain `Bool`, updated by inbound `AgentSessionStatusUpdate` messages. The trailing-5 `events: [HookEvent]` buffer is dropped — there's no longer any UI that renders structured event history. |
| `ClaudeProjectInfo` (`ClaudeSpyNetworking/Models/RelayMessages.swift`) | `AgentProject`. `agent: CodingAgent` → `pluginID: String`. |
| `paneState.claudeSession`, `hasClaudeSession`, `claudePanes`, `markDetectedClaudeSessions` (across `WindowManager`, `AppCoordinator`, `TmuxService`) | `agentSession`, `hasAgentSession`, `agentPanes`, `markDetectedAgentSessions`. |
| `TmuxService.detectClaudePanes()` | `detectAgentPanes()`. Internal: fans out over plugin manifests' `process_names`; falls back to per-plugin `sidecar.detect_pane(...)` RPC when a manifest declares `requires_rich_detection: true`. |

### 10.5. Settings migration

On first launch of the new version:
- Read `Settings.claudeCommandPath` and `Settings.codexCommandPath` from `UserDefaults`.
- If non-default, write to `~/.gallager/state/plugins/claude-code/settings.json` (as `command_path`) and `~/.gallager/state/plugins/codex/settings.json` (as `command_path`).
- Remove the old keys from `UserDefaults`.

The migration code lives in the app (in the runtime's bootstrap, not in the plugins). Plugins see fresh settings; they don't know migration happened.

### 10.6. Existing `claude plugin install gallager` users

On first launch of the new version, the bundled Claude Code plugin's `is_installed` RPC reports the existing install (the marketplace name `gallager` is unchanged). `sidecar.install()` against an existing install is a refresh, not a fresh add — it points the marketplace at the new bundle path inside the new `.app`. Users see no install prompt.

## 11. Wire compatibility & rollout

This is a flag-day release on both wire and binary fronts:

- `ClaudeSpyNetworking/Models/VersionCompatibility.swift` minimum bumps by one breaking-change increment.
- A v-new viewer refuses to pair with a v-old host; a v-new host refuses to serve a v-old viewer. The existing compatibility check surfaces the upgrade prompt that's already there.
- No dual-emit, no legacy event shapes, no deprecation window. `HookEvent` / `HookAction` are deleted outright.
- Paired-host cross-version skew (one Mac on v-new, another Mac on v-prev-prev paired to the same iOS) still gets `decodeIfPresent` for incidental field additions in `RelayMessages`, per the existing rule for ROUTINE skew. But this release's break is a deliberate format change, not routine skew — VersionCompatibility handles it.

Order of work in the single PR:
1. Land `GallagerPluginProtocol` (Mac-only) and the new shared `ClaudeSpyNetworking` types (`AgentResponseRequest`, `AgentSessionStatusUpdate`, `PluginPresentation`).
2. Land `ClaudeSpyPluginRuntime` (Mac-only, no integration yet).
3. Land `ClaudeCodePluginCore` + `ClaudeCodePluginSidecar` (executable). Bundle into `Resources/plugins/claude-code/`.
4. Land `CodexPluginCore` + `CodexPluginSidecar`. Bundle into `Resources/plugins/codex/`.
5. Wire the runtime into `AppCoordinator`. Replace agent switches with `pluginManager.<method>(pluginID:)` calls.
6. Migrate Settings (`claudeCommandPath`/`codexCommandPath` → per-plugin).
7. Rename `ClaudeSession`/`ClaudeProjectInfo` → `AgentSession`/`AgentProject`. Rename pane state fields.
8. Update iOS: delete `EventRowView` and all `HookEvent`/`HookAction` decode paths; reroute `ResponseViews/*` from `HookAction` cases to `AgentResponseRequest` cases; consume `agent_session_status` and `plugin_presentations` messages.
9. Delete `HookServerService`, `HookEvent`, `HookAction`, all `*Body` structs, `CodingAgent`, the old per-agent Swift services, the repo-root `plugin/` folders.
10. Bump `VersionCompatibility` minimum.
11. Update existing E2E scenarios. Add the `EchoPlugin` reference fixture + a new E2E scenario per platform.

## 12. Sidecar supervision

`SidecarSupervisor` (in `ClaudeSpyPluginRuntime`) manages one process per enabled plugin.

**Lifecycle**:
1. App launch → for each enabled plugin: locate `bin/sidecar`, spawn with `state_dir`, `plugin_root`, `app_version` in env. Stdin/stdout piped for JSON-RPC; stderr → per-plugin log file at `~/.gallager/state/plugins/<id>/logs/sidecar.log` (size-rotated, 5 MB max retained).
2. Send `initialize` with 10s timeout. On timeout or non-success, mark plugin as **failed-init**, UI shows error, plugin stays disabled. No retry until user action.
3. Once initialized, start a 30s heartbeat via `health` RPC. Three consecutive misses → considered crashed.
4. On app quit: `shutdown` RPC with 3s deadline, then SIGTERM, then SIGKILL after 5s.

**Crash policy** (per-plugin restart counter in a 60s sliding window):
- 1st/2nd/3rd crash within the window: restart with backoff 1s / 2s / 4s.
- 4th+ crash: **auto-disable the plugin**, surface a banner showing the last 50 lines of stderr + a "Re-enable" button. No further auto-restart.

## 13. Error handling

| Failure | Response |
|---|---|
| Manifest invalid (third-party install) | Reject before unpacking; leave state clean. UI message names the offending field. |
| Sidecar binary missing or non-executable | Plugin enters failed-init, no spawn attempt. Surfaced in Settings. |
| RPC `MethodNotFound` from sidecar | Treat as "feature not supported"; gracefully degrade (e.g., no `detect_pane` → fall back to manifest `process_names`). |
| Malformed JSON from sidecar | Log and treat as transient; if persistent across N events, supervisor restarts the process. |
| `install` RPC fails (e.g., `claude` binary not on PATH) | Surface in Settings; plugin enters "installed but not hooked up" state. Offer retry + manual-install instructions link. |
| `apply_settings` invalid | Return error to UI; keep old values; show error inline next to the offending field. |
| Sidecar emits an event for a plugin that's been disabled | Drop silently with a debug log. (Race during disable.) |

## 14. Testing strategy

Three layers:

1. **Unit / integration tests in each `*PluginCore` package** (Point-Free Dependencies, swift-testing). Scanner / installer / event-translator logic is the bulk of each plugin core and is independently testable — same as today's tests for `CodexProjectScanner`/`CodexPluginInstaller`, just relocated.
2. **JSON-RPC contract tests in `GallagerPluginProtocol`**. `MockSidecar` (drives app-side tests) and `MockApp` (drives sidecar-side tests). Each plugin core's RPC adaptor gets a roundtrip smoke test.
3. **E2E scenarios in `ClaudeSpyE2ELib`**. See Section 15 — non-trivial migration.

Explicitly out of v1 testing scope (manual-smoke-tested only):
- Third-party HTTPS install (would require network in CI).
- Update flow.
- Signature verification (not in v1).

## 15. End-to-end test migration

The E2E suite is non-trivially affected. Roughly 10 scenarios drive the system today by stubbing raw hook payloads into the Mac's local HTTP hook server, then asserting on iOS UI that reflects the resulting `HookEvent`. After this change, both ends of that move:
- **Inbound**: `HookServerService` is gone; payloads must arrive at a per-plugin Unix socket instead.
- **Outbound**: the iOS strings the scenarios assert on (`"Prompt Submitted"`, the event-row labels) come from `EventRowView`, which is deleted. iOS state observable to tests becomes thinner: presentation labels, session status badges, and the response-form UIs.

### 15.1. DSL changes in `ClaudeSpyE2ELib/DSL/TestScenario.swift`

| Today | Tomorrow |
|---|---|
| `case macSendHookEvent(json:, tmuxPane:, projectPath:, instance:)` — POSTs to `localhost:port/api/hooks` via `MacAppHTTPClient.sendHook` | `case macSendRawHookPayload(pluginId:, json:, env: [String: String], instance:)` — connects to `~/.gallager/state/plugins/<pluginId>/ingress.sock` (resolved per the test instance's isolated state dir, Section 15.4) and writes a length-prefixed JSON frame with `{ context: env, payload: <json> }`. Tests provide the project path / tmux pane via the env map (`CLAUDE_PROJECT_DIR`, `TMUX_PANE`, etc.), matching what real hook commands set. |
| (none) | `case macInstallBundledPlugin(pluginId:, instance:)` — explicitly install the bundled plugin's hooks into a fake host-agent config (for scenarios that exercise the install flow). |
| (none) | `case macSpawnSidecar(pluginId:, executablePath:, instance:)` — load a non-bundled plugin from a fixture path. Used by the `EchoPlugin` scenario. |
| `iosWaitForElement(.labelContains("Prompt Submitted"))` — relies on `EventRowView` displaying event titles | Replace with assertions on what iOS now shows: session badge state (`.labelContains("Working")` / `.labelContains("Attention")`), presentation labels (`.labelContains("Claude Code")`), or response-form visibility (`.labelContains("Approve")` for permission requests). |

`MacAppHTTPClient.sendHook` (in `Drivers/MacOS/MacAppHTTPClient.swift`) is replaced by a new `MacAppPluginIngressClient` that connects to the per-plugin Unix socket. The old `/api/hooks` HTTP path is deleted.

### 15.2. Scenarios that need updating

Scenarios that currently call `macSendHookEvent`:
- `ClaudeSessionUpdatesScenario` — uses `UserPromptSubmit` and `SessionEnd`. Updates: pass `pluginId: "claude-code"`, move project/pane to env, replace `.labelContains("Prompt Submitted")` assertion with a status-badge assertion (`Working`) since "Prompt Submitted" no longer renders on iOS.
- `ClaudeSessionRepliesPersistScenario`, `ClaudeSessionsShowScenario` — same migration.
- `AskUserQuestionScenario`, `BadgeAggregationScenario`, `MarkHandledScenario`, `MarkdownWriteOpenSuggestionScenario` — exercise permission-request flows that map to `AgentResponseRequest.permission`. The form UI is unchanged; only the wire shape changes. Assertions on the form (button labels, suggestion text) stay; assertions on EventRowView text are removed.
- `ClipboardSyncScenario`, `GallagerCLIScenario`, `HostDisconnectClearsSessionsScenario`, `FileBrowserScenario` — touch hooks tangentially; small mechanical updates.

Estimated impact: every scenario keeps its intent and most of its steps; the changes are mechanical (DSL rename + env-map instead of query-param + assertion shift from event labels to status/form labels).

### 15.3. New scenarios to add

- **`PluginRuntimeBasicsScenario`** — uses the `EchoPlugin` fixture (Section 15.5). Verifies the full pipeline for a non-bundled plugin: spawn, init, ingress, translate, emit, iOS receives `agent_session_status`, presentation bundle reaches iOS.
- **`PluginCrashRestartScenario`** — Echo plugin force-crashes on a specific raw payload; supervisor restarts it; verify the plugin recovers and the next event flows normally.
- **`PluginCrashLoopDisableScenario`** — Echo plugin crashes 4+ times in 60s; supervisor disables it; verify the disabled-plugin banner appears and no further events flow.
- **`PluginResponseRequestScenario`** — Echo plugin emits a `PermissionResponseRequest`; iOS shows the form; user approves; verify the response message round-trips back to the Echo plugin.
- **`PluginPresentationUpdateScenario`** — Echo plugin's version bumps mid-session; Mac re-pushes the presentation bundle to iOS; verify iOS picks up the new icon/name without reconnect.
- **`PluginProjectPushScenario`** — Echo plugin pushes `set_projects` on init, then pushes a new list mid-session via the `{"_test": "set_projects"}` payload; verify the project sidebar reflects both states without the app asking. Also verifies that the manual-refresh button results in a `refresh_projects` RPC reaching the sidecar.
- **`PluginAskUserQuestionRoundTripScenario`** — Echo plugin emits an `AgentResponseRequest.askUserQuestion` with two questions (one single-select, one multi-select with `allowFreeText`). iOS form walks through both. On submit, verify the Echo sidecar receives `deliver_response` with the expected `AskUserQuestionResponse`, and that the sidecar calls back `send_text` / `send_keys` matching the test's configured "delivery script". (Tests that the structured-answer → agent-keystroke translation lives in the sidecar, not iOS.)

### 15.4. Storage isolation for plugins

The existing `--e2e-test` argument already swaps `PreferencesService` / `SecretsService` for in-memory implementations and the `--tmux-socket` flag isolates the tmux server (per `docs/e2e-testing.md`'s "Storage isolation" and "Tmux socket isolation" sections).

Plugins need a third axis: their state dirs (`~/.gallager/state/plugins/<id>/` and the `~/.gallager/plugins/<id>/` install dir) must be redirected to a per-test temp root. Add a new launch arg `--gallager-state-root <path>` that overrides the default base path for both. The orchestrator allocates a temp dir per scenario, passes it to the app, and removes it on cleanup.

Bundled plugins still come from `Gallager.app/Contents/Resources/plugins/` regardless of state-root (they're read-only inside the .app). The state-root only affects per-plugin runtime state, install dir for third-party plugins, and the ingress socket location (which is why the DSL needs to know the test instance's state-root to compute the socket path).

### 15.5. `EchoPlugin` reference fixture

Lives at `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Fixtures/EchoPlugin/` and is **built as part of the test target**, not the app. Layout matches the bundled-plugin shape:

```
Fixtures/EchoPlugin/
  plugin.json                   { id: "echo", display_name: "Echo", ... }
  bin/sidecar                   Swift binary, built from a small fixture target
  assets/icon.png               a tiny solid-color square
```

The sidecar:
- Implements all RPCs minimally.
- On `initialize`, sends a `set_projects` callback with whatever list the scenario configured via env var `ECHO_PROJECTS_JSON` (defaults to empty list). Sends an updated `set_projects` whenever the scenario triggers `{"_test": "set_projects", "projects": [...]}` so tests can exercise the push-based project refresh path.
- On `refresh_projects`, just resends the current configured list (so tests can verify the manual refresh button reaches the sidecar).
- On `translate_event`, recognises a small set of test control payloads and emits a `PluginEvent` shaped by the test's intent:
  - `{"_test": "set_status", "working": true, "attention": false}` → emit a `PluginEvent` with just those status bits.
  - `{"_test": "notify", "title": "...", "body": "..."}` → emit a `PluginEvent` with a `notification`.
  - `{"_test": "request_permission"}` → emit a `PluginEvent` with a `permission` `response_request`.
  - `{"_test": "request_ask_user_question", "questions": [...]}` → emit an `askUserQuestion` `response_request` so the AskUserQuestion round-trip can be exercised.
  - `{"_test": "request_approve_plan", "plan": "...", "allow_edit": true}` → emit an `approvePlan` `response_request`.
  - `{"_test": "open_file_suggestion", "path": "..."}` → emit a `PluginEvent` with an `openFileSuggestion` app action.
  - `{"_test": "set_projects", "projects": [...]}` → call back `set_projects` with the given list (without emitting a `PluginEvent`).
  - `{"_test": "crash"}` → call `abort()`. Used by `PluginCrashRestartScenario`.
- On `deliver_response`, records the received `AgentResponse` into a per-request file at `${state_dir}/responses/<request_id>.json` (so tests can read it back and assert) AND calls a sequence of `send_text` / `send_keys` callbacks as configured by an optional `_delivery_script` field on the original request payload. Lets tests verify both the sidecar contract (received the right structured answer) and the agent-driver contract (emitted the right keystroke sequence).
- No bridge script; tests inject payloads directly via `macSendRawHookPayload`.

Living as a fixture means the Echo plugin doesn't ship in `Gallager.app` and never appears in the bundled plugin list — it's only loaded via `macSpawnSidecar(pluginId: "echo", executablePath: "${fixture_path}", …)`.

### 15.6. Out-of-scope for the migration

These E2E gaps stay manual smoke tests (consistent with Section 14):
- Real third-party install from an HTTPS manifest URL.
- Real Claude Code / Codex CLI interaction (we've never run actual `claude` or `codex` binaries in E2E — we've always stubbed at the hook layer; that doesn't change).
- Marketplace update flow.

## 16. Non-goals for v1

Designed-against later, not now:

- **Plugin signing / publisher identity.** Hash pinning + TLS only. Manifest shape leaves room to add signature fields later without breaking compatibility.
- **macOS App Sandbox / seatbelt confinement.** Plugins run as the user with full permissions. Convention enforces state-dir isolation; v2 can add a sandbox profile generated from a manifest `capabilities` block.
- **In-app plugin browser / discovery marketplace.** v1 install is "paste a URL." Discovery UI is v2.
- **Hot-reload of plugin code without restart.** Plugin updates require a sidecar restart (cheap, but observable).
- **Cross-plugin event correlation.** Each plugin is independent. Sessions tagged by plugin; no shared identity.
- **Plugin-defined iOS UI of any kind.** iOS surface is closed-set (`AgentResponseRequest` + status + presentation). Adding a new iOS form requires a coordinated app + plugin update.
- **Hook handling when Gallager is offline.** Events drop on the floor.
- **Multiple sidecar instances per plugin.** One process; plugins manage their own per-session state.

## 17. Resolved design details

These were open questions in the brainstorm draft. Resolutions below.

### 17.1. `AppAction` enum (resolved)

Audit of Mac-side code that inspects `HookEvent` shape for side effects today:

- **`MarkdownOpenSuggestionStore`** (`Managers/MarkdownOpenSuggestionStore.swift`):
  - On `.postToolUse` with `Write` tool to a `.md`/`.markdown` path → adds an "open this file?" suggestion to the pane.
  - On `.userPromptSubmit` → dismisses outstanding suggestions for that pane.
- **`MirrorWindowManager`** (`Managers/MirrorWindowManager.swift`):
  - On `.sessionEnd` → clears the pane's session, clears yolo mode, AND closes the pane if `closePaneOnSessionEnd` is enabled and the reason was `promptInputExit`.
  - On `.permissionRequest` with yolo mode on AND `body.isYoloAutoApprovable == true` → auto-approves by sending the Enter key after a 500 ms delay.
  - Other cases → just buffer the event into the session model.
- **`HookActionUI.swift`** (in `ClaudeSpyCommon/UI/`): supplies `title`/`subtitle` strings for the per-`HookAction`-case display. Used today by `EventRowView` (which is deleted) and notification building (which moves into the sidecar).
- **`HookNotificationExtensions.swift`**: `buildNotification()` constructs `(title, body)` from event shape. In the new design, the sidecar bakes title+body and emits a `notification` on the `PluginEvent`; this file becomes part of the Claude Code sidecar core.

Resolution — final `AppAction` enum:

```swift
enum AppAction: Codable, Sendable {
    /// Surface a "open this file?" suggestion in the pane's UI.
    /// Used by the existing markdown-write feature.
    case openFileSuggestion(sessionId: String, path: String, displayName: String, isPlan: Bool)

    /// Dismiss any outstanding file-open suggestions for this session.
    /// Emitted when the user submits a new prompt (suggestion is no longer relevant).
    case dismissFileSuggestions(sessionId: String)

    /// Close the tmux pane backing this session IF the user has the
    /// `closePaneOnSessionEnd` preference enabled. App reads the pref;
    /// sidecar just emits the intent. The sidecar emits this on session-end
    /// events; whether the close actually happens is the app's decision.
    case closePaneIfPreferenceAllows(sessionId: String)
}
```

**Yolo auto-approval is NOT an AppAction** — it's resolved by adding `isAutoApprovable: Bool` to `PermissionRequest` (Section 7.2). When the Mac receives a `response_request: .permission` with `isAutoApprovable == true` for a pane in yolo mode, it immediately calls `deliver_response` on the sidecar with `.allow`, no iOS form ever shown. Plugin doesn't need to know about yolo at all.

**Session-store event buffering goes away** — `AgentSession.events: [HookEvent]` (the trailing-5 buffer) is dropped (already covered in Section 10.4). Status derivation comes from `update_session_status` callbacks directly.

`AppAction` grows by adding new cases when future Mac-side features need plugin-driven triggers; that's a coordinated app + plugin update each time (acceptable since AppActions are inherently agent-blind features).

### 17.2. Claude Code & Codex `HookAction` → sidecar behavior table (resolved)

For each of the 30 current `HookAction` cases, here is what the Claude Code sidecar does when it parses one. Most cases just update status; a smaller set emit notifications, response requests, or app actions. Cases that today are "received and ignored" stay log-and-drop.

| HookAction case | New sidecar behavior |
|---|---|
| `sessionStart` | `update_session_status(working: false, attention: false)`; emit `notification("Session started")` |
| `setup` | log-and-drop |
| `preToolUse` | `update_session_status(working: true, attention: false)` |
| `postToolUse` | `update_session_status(working: true, attention: false)`. If `body.toolInput` is `.write` to a `.md`/`.markdown` path → also emit `app_actions: [.openFileSuggestion(sessionId, path, displayName, isPlan)]` |
| `postToolUseFailure` | `update_session_status(working: true)` (still in the loop) |
| `sessionEnd` | `update_session_status(working: false, attention: false)`; emit `app_actions: [.closePaneIfPreferenceAllows(sessionId)]` when `body.reason == .promptInputExit` |
| `permissionRequest` | Dispatch by `body.toolInput`: `AskUserQuestion` → emit `response_request: .askUserQuestion(...)`; `ExitPlanMode` → emit `response_request: .approvePlan(...)`; everything else → emit `response_request: .permission(...)` with `isAutoApprovable = body.isYoloAutoApprovable`. Also emit `notification` with the existing per-tool copy. |
| `permissionDenied` | log-and-drop (denial was already user-driven; no new state to surface) |
| `notification` | If `body.notificationType != "permission_prompt"` && `!= "idle_prompt"` && `body.message != nil` → emit `notification(title: agent.displayName, body: "<project>: <message>")` |
| `userPromptSubmit` | `update_session_status(working: true, attention: false)`; emit `app_actions: [.dismissFileSuggestions(sessionId)]` |
| `stop` | `update_session_status(working: false, attention: true)`; emit `notification(title: "Claude is waiting…", body: lastAssistantMessage ?? "Claude is waiting for your input")`; emit `response_request: .replyAfterStop(lastAssistantMessage)` |
| `subagentStart` | `update_session_status(working: true)` |
| `subagentStop` | log-and-drop (main loop's `working` state is the source of truth) |
| `teammateIdle` | `update_session_status(attention: true)`; emit `notification("Teammate is idle")` |
| `taskCompleted` | emit `notification(title: "Task completed", body: taskSubject)` |
| `preCompact` | log-and-drop |
| `postCompact` | log-and-drop |
| `instructionsLoaded` | log-and-drop |
| `stopFailure` | `update_session_status(attention: true)`; emit `notification("Stop error: <errorType>")` |
| `configChange` | log-and-drop |
| `cwdChanged` | log-and-drop (project re-detection happens through the FSEvents-driven `set_projects` push, not here) |
| `fileChanged` | log-and-drop |
| `elicitation` | `update_session_status(working: true)` |
| `elicitationResult` | log-and-drop |
| `worktreeCreate` | log-and-drop |
| `worktreeRemove` | log-and-drop |
| `taskCreated` | emit `notification(title: "Task created", body: taskSubject)` |
| `userPromptExpansion` | `update_session_status(working: true)` |
| `postToolBatch` | log-and-drop |
| `unknown` | log-and-drop with WARN level log |

**Codex sidecar audit**: Codex's hook event set is a subset of Claude's plus `PostCompact` and `SubagentStart`. The mapping is identical to the table above for the cases Codex supports. `PermissionRequest` in Codex carries the same shape as Claude's, so the same dispatch logic applies. The only Codex-specific behavior: when the sidecar parses a `SessionStart`, it also writes a sidecar correlation file at `~/.claudespy/codex-sessions/<tmux_pane>.json` (today's mechanism to correlate Codex session IDs to tmux panes — see `docs/codex-cli-integration-plan.md` §5).

### 17.3. Settings schema JSON (resolved)

Per-plugin settings UI is driven by `ui/settings.json`. The app renders a SwiftUI form from the schema; saved values land at `~/.gallager/state/plugins/<id>/settings.json` and reach the sidecar via `apply_settings`.

```json
{
  "schema_version": 1,
  "sections": [
    {
      "title": "Command",
      "fields": [
        {
          "id": "command_path",
          "type": "string",
          "label": "Claude CLI command",
          "default": "claude",
          "placeholder": "claude",
          "help": "Absolute path or $PATH-discoverable name."
        }
      ]
    },
    {
      "title": "Behavior",
      "fields": [
        {
          "id": "auto_run",
          "type": "boolean",
          "label": "Auto-launch Claude when opening a project",
          "default": true
        },
        {
          "id": "log_level",
          "type": "picker",
          "label": "Sidecar log level",
          "default": "info",
          "options": [
            { "value": "debug", "label": "Debug" },
            { "value": "info",  "label": "Info" },
            { "value": "warn",  "label": "Warning" },
            { "value": "error", "label": "Error" }
          ]
        }
      ]
    }
  ]
}
```

Supported field types in v1 (closed set; render impl in `ClaudeSpyPluginRuntime`):

| `type` | UI | Extra fields | Stored as |
|---|---|---|---|
| `string` | `TextField` | `default`, `placeholder?`, `help?` | string |
| `boolean` | `Toggle` | `default` | bool |
| `int` | `Stepper` w/ optional `TextField` | `default`, `min?`, `max?`, `step?`, `help?` | int |
| `picker` | `Picker` (`.segmented` if ≤4 options, otherwise menu) | `default`, `options: [{value, label}]`, `help?` | string (the picked `value`) |
| `file_path` | macOS `NSOpenPanel` chooser; iOS doesn't render this field type | `default?`, `mustExist: bool`, `directoriesOnly: bool`, `help?` | string |

Validation happens in two places: the UI rejects malformed input (e.g., int out of range, missing file when `mustExist`); the sidecar's `apply_settings` does semantic validation (e.g., "does this binary actually launch?") and can reject by returning `{ status: "error", message: "..." }`. Rejection keeps the previous values; UI surfaces the error inline.

iOS does NOT render the per-plugin settings UI — settings are Mac-only. The iOS app shows a read-only "Configured by Mac" placeholder if the user navigates to plugin details.

### 17.4. `gallager plugin` CLI verbs (resolved)

Follow the existing `gallager` CLI structure (Unix socket JSON-RPC, `--json` flag for machine output, exit codes for shell scripting). New verbs under the `plugin` namespace:

| Command | RPC method | Description |
|---|---|---|
| `gallager plugin list [--json]` | `plugin.list` | Print installed plugins: id, version, enabled, source (`bundled` / URL). Tabular by default; JSON with `--json`. |
| `gallager plugin info <id> [--json]` | `plugin.info` | Full info for one plugin: manifest, install path, state-dir size, log file path, last update check, capabilities. |
| `gallager plugin install <url>` | `plugin.install` | Trigger the install flow from a manifest URL. Prints the confirmation prompt details to stdout and reads `y`/`n` from stdin (unless `--yes`). Exits non-zero on rejection or install failure. |
| `gallager plugin remove <id>` | `plugin.remove` | Uninstall the plugin. Prompts to also delete the state dir (or `--keep-state` / `--delete-state`). Bundled plugins refuse. |
| `gallager plugin enable <id>` | `plugin.enable` | Enable a disabled plugin (spawns sidecar). |
| `gallager plugin disable <id>` | `plugin.disable` | Disable an enabled plugin (shuts down sidecar; leaves files). |
| `gallager plugin update [<id>]` | `plugin.update` | Check for updates (no id → all); apply with `--apply`. Without `--apply`, just prints which versions are newer. |
| `gallager plugin call <id> <method> [<json>]` | `plugin.call` | Direct sidecar RPC for testing/debugging. Reads JSON params from arg or stdin; prints the JSON response. Bypasses normal flow. |
| `gallager plugin logs <id> [-f] [--lines N]` | `plugin.logs` | Print the sidecar's log file. `-f` tails. `--lines` limits output. |

All commands use the existing socket-discovery path (`GALLAGER_SOCK` env → `$TMPDIR/gallager.sock` → fallback). All support `--json` for structured output. Error messages go to stderr; exit codes: `0` success, `1` user error (bad args, plugin not found, install rejected), `2` system error (Gallager not running, socket unreachable), matching today's gallager CLI behavior.

### 17.5. Per-plugin log viewer in Settings (resolved)

The sidecar's stderr is captured to `~/.gallager/state/plugins/<id>/logs/sidecar.log` (size-rotated, 5 MB max retained per Section 12). Settings → Plugins → `<id>` → **View Logs** button opens a sheet:

```
┌─ Logs: Claude Code ──────────────────────────────────────────────┐
│                                                          [↻ Tail]│
│ [Show in Finder]  [Copy All]                            [Clear]  │
│ ────────────────────────────────────────────────────────────────│
│  2026-05-24 18:32:11  INFO   Initialized, scanning projects…    │
│  2026-05-24 18:32:11  INFO   Found 42 projects                  │
│  2026-05-24 18:32:11  DEBUG  set_projects sent (42 items)       │
│  2026-05-24 18:35:02  INFO   Ingress: PreToolUse received       │
│  ...                                                            │
└─────────────────────────────────────────────────────────────────┘
```

Implementation:
- SwiftUI `ScrollView` containing a monospaced `Text` of the file's last 256 KB (truncated head with an ellipsis if larger).
- Auto-tail via `DispatchSourceFileSystemObject` watching the file for `.extend`; new lines append to the view.
- "Show in Finder" reveals the log file.
- "Copy All" copies the visible buffer to the clipboard.
- "Clear" truncates the log file (with confirmation) — sidecar continues writing on next event.
- No filtering, no search, no level toggles in v1. The text viewer is plain.

Total UI surface: one sheet, one SwiftUI view, ~150 lines. Reuses the monospaced-text patterns already used by `gallager` CLI output rendering.

## 18. References

- Codex CLI Integration Plan (this design's direct ancestor): `docs/codex-cli-integration-plan.md`
- Distributed Architecture: `docs/distributed-architecture-plan.md`
- Gallager CLI API: `docs/gallager-cli-api.md`
- Services Reference: `docs/services-reference.md`
- Swift patterns: `docs/swift-patterns.md`
