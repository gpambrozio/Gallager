# Coding-Agent Plugin System — v1 (in-process)

Status: Design
Date: 2026-05-29
Author: Brainstormed with Claude

> **Companion:** `2026-05-29-plugin-system-v2-external-sidecar-plugins.md` describes the
> out-of-process / third-party tier that attaches *behind the same contract* this document
> defines. Read this first; v2 is purely additive.

## 1. Goal

Make the Gallager core app **agent-blind**: pane mirroring, tmux integration, the event
dispatcher, the `gallager` CLI, pairing, the relay path, and the iOS surface know nothing about
any specific coding agent. All agent-specific logic (project discovery, hook installation,
raw-event translation, command resolution, notification copy, icons) lives behind **one Swift
contract**, the `PluginCore` protocol, implemented by a per-agent module.

There are two distinct promises here, and it is easy to conflate them. This document is explicit
about which one v1 delivers:

- **v1 promise (this document):** Agent-specific code lives in a self-contained `*PluginCore`
  module (`ClaudeCodePluginCore`, `CodexPluginCore`). Adding an agent is a **new compiled module +
  one registry entry**. It never touches the iOS app, the relay server, or the agent-blind core —
  but it **is a Gallager recompile**.
- **v2 promise (companion document):** the *same* `PluginCore` contract can be satisfied by an
  out-of-process, URL-distributed, third-party plugin via a transport adapter, with no change to
  the dispatcher, iOS, or relay. v1 ships **zero** third-party and **zero** out-of-process plugins.

The durable, stable artifact is **the contract**, not the process model or any wire encoding.
Five things make up the contract; everything else is implementation detail that v2 may swap:

1. the `PluginCore` actor protocol (§4),
2. the `PluginEvent` envelope — the single state-change carrier (§5),
3. the `AgentResponseRequest` / `AgentResponse` closed vocabulary (§7),
4. the on-disk layout under `~/.gallager/` (§9),
5. the ingress frame format (§8).

The in-process ↔ out-of-process seam sits exactly at `PluginCore`. v1 conformers are direct
in-process Swift actors. v2 adds a `SidecarPluginCore` conformer that marshals the same methods
over a transport. Nothing upstream of `PluginCore` changes.

## 2. Background: what this replaces

The current app wires two agents in directly: a `CodingAgent` enum, a local HTTP `HookServerService`
ingesting hook POSTs, a 30-case `HookAction` event enum, per-agent Swift scanners/installers, and
hardcoded `"Claude Code"` notification copy. Every new agent means new `case` arms threaded through
the core app, the iOS app, and the wire models.

v1 replaces that with a single agent-blind contract. Crucially, it does **not** reach for an
out-of-process sidecar / URL-distribution / sandbox apparatus to do so: the two agents that ship
are first-party Swift that compiles into the app, so they run **in-process** behind the contract.
The process boundary, a wire transport, supervision, and a third-party install perimeter are real
costs that buy nothing for first-party plugins — they belong to the third-party tier, which v1 does
not build (see the companion v2 spec). v1 is the smallest design that makes the core agent-blind.

## 3. Design decisions (locked in)

| Decision | Choice |
|---|---|
| **Runtime** | **In-process.** Each enabled bundled plugin is an `actor` conforming to `PluginCore`, constructed at launch from a compile-time registry and held by `PluginRegistry`. No child process, no stdio framing, no JSON-RPC. App→plugin calls are direct `await core.method(...)`; plugin→app callbacks go through an injected `PluginHost`. |
| **Crash model** | **Crashes accepted.** An in-process plugin shares Gallager's process and fate. A Swift *trap* (force-unwrap, precondition, out-of-bounds) in a core takes down the app — it is an app bug, fixed like any other. There is **no** supervisor, restart, backoff, crash-loop-disable, or heartbeat in v1; those are v2 (out-of-process) concerns. Thrown Swift errors are caught at the dispatch boundary and logged; only traps are fatal. |
| **Distribution** | **Bundled only.** Plugins ship inside `Gallager.app/Contents/Resources/plugins/<id>/` (manifest + icon; no binary — the core is compiled into the app). They update only when the app updates. No HTTPS install, no download, no zip, no hash pinning, no trust prompt — all deferred to v2. |
| **Ingress** | **One app-owned Unix socket** (`~/.gallager/state/ingress.sock`). Host-agent hook bridges write length-prefixed frames carrying their `plugin_id`; the app routes each frame to the owning core's `handleIngress`. No per-plugin socket. |
| **iOS surface** | iOS knows nothing about plugins, the contract, or the process model. It receives a closed, app-defined wire format (status updates, the 5-case `AgentResponseRequest` vocabulary, pre-baked notifications, a per-plugin presentation bundle, the terminal stream). The plugin system stops at the Mac boundary. |
| **Settings** | Typed Swift `Settings` struct per plugin core + one hand-written SwiftUI form keyed by plugin id. No JSON-schema form interpreter. |
| **Wire compat** | Flag-day break. Bump `VersionCompatibility` minimum by one breaking increment; v-new viewers refuse v-old hosts and vice versa. No dual-emit, no legacy event types. Cross-host relay skew keeps the existing `decodeIfPresent` rule for incidental field additions. |

## 4. The plugin contract — `PluginCore`

The single seam. v1 conformers are in-process actors in each `*PluginCore` module. The app drives
these methods; the plugin calls back through the `PluginHost` it receives at `initialize`.

```swift
/// The agent-specific contract. One conformer per agent module. In v1 every
/// conformer is an in-process actor; v2 adds a transport-adapter conformer.
public protocol PluginCore: Actor {
    /// Called once after construction. `host` is the callback channel. THROW to
    /// enter failed-init (the plugin is left disabled, error surfaced in Settings).
    /// Identity, presentation, and pane-detection data come from the MANIFEST (§10),
    /// NOT from the core — the app needs them *before* the core ever runs (to list a
    /// disabled or failed-init plugin in Settings, and to detect panes for a plugin
    /// that hasn't initialized yet). So `initialize` returns nothing.
    func initialize(_ env: PluginEnv, host: any PluginHost) async throws

    /// A raw host-agent payload arrived on the app-owned ingress socket tagged
    /// with this plugin's id. Translate it into a PluginEvent, or return nil to
    /// drop (log-and-ignore). The app dispatches the returned envelope.
    func handleIngress(_ frame: IngressFrame) async -> PluginEvent?

    /// iOS submitted an AgentResponse for a request this core previously emitted
    /// (matched by request_id). The core looks up the context it retained and
    /// drives delivery to the host agent — typically host.sendText / host.sendKeys.
    func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async

    /// The user clicked "refresh projects". The core SHOULD rescan and call
    /// host.setProjects; it MAY no-op if its data is already fresh.
    func refreshProjects() async

    /// Gallager is about to auto-launch the agent in a tmux pane for a project.
    /// Return the command/env/args, or nil to decline. Gated upstream by the
    /// plugin's `autoRun` setting.
    func commandForLaunch(projectPath: String) async -> LaunchCommand?

    /// Register / remove / query the host-agent hook bridge (writes into the
    /// agent's own hook config, e.g. ~/.claude/.../hooks.json).
    func install() async throws -> InstallResult
    func uninstall() async throws
    func isInstalled() async -> Bool

    /// Apply user settings (raw JSON from settings.json). The core decodes its
    /// typed struct and runs semantic validation; return .error to surface inline.
    func applySettings(_ raw: Data) async -> SettingsResult

    /// Graceful teardown (stop FSEvents watchers, flush). Called on disable / quit.
    func shutdown() async
}
```

```swift
/// The callback channel the app hands each core at initialize. Sendable so a
/// core actor can hold and call it. Every method is async so the app can
/// serialize/route without the core caring how.
public protocol PluginHost: Sendable {
    /// Replace the app's project list for this plugin (full list, not
    /// incremental — lists are tens of items). Push-based: the app never asks.
    func setProjects(_ projects: [AgentProject]) async

    /// Push a PluginEvent into the session pipeline (used when the core
    /// generates events without an incoming ingress frame — e.g. an FSEvents
    /// watcher tick).
    func emit(_ event: PluginEvent) async

    /// Write text to the tmux pane backing this session (verbatim, no key
    /// processing). Used to deliver prompt/reply text or free-text answers.
    func sendText(sessionID: String, _ text: String) async

    /// Send a key sequence to the pane (e.g. [.down, .down, .space, .enter]).
    /// Used to drive in-terminal menus (AskUserQuestion, permission prompts).
    func sendKeys(sessionID: String, _ keys: [PluginTmuxKey]) async

    /// Structured log line, appended to the plugin's log file and surfaced in
    /// Settings → View Logs.
    func log(_ line: LogLine) async
}
```

Supporting value types (all `Sendable`):

```swift
public struct PluginEnv: Sendable {            // handed to initialize
    public let pluginRoot: URL                 // Resources/plugins/<id>/ (read-only)
    public let stateDir: URL                   // ~/.gallager/state/plugins/<id>/
    public let appVersion: String
    public let settings: Data                   // current settings.json bytes (may be empty);
                                                // the AUTHORITATIVE initial settings value (§11)
}

// NOTE: there is no `PluginInfo`. Identity / presentation / pane-detection data
// (id, display_name, short_name, version, process_names, icon, color) is owned
// SOLELY by the manifest (§10), which the app reads before constructing the core.
// This avoids a two-source-of-truth split between the manifest and an init return.

public struct LaunchCommand: Sendable {
    public let command: String
    public let args: [String]
    public let env: [String: String]
}

public enum InstallResult: Sendable { case installed(message: String); case alreadyInstalled }
public enum SettingsResult: Sendable { case applied; case error(field: String?, message: String) }
public struct LogLine: Sendable { public let level: LogLevel; public let message: String }
public enum LogLevel: String, Sendable { case debug, info, warn, error }
```

**The contract is deliberately small.** It has no separate App→plugin / plugin→App method split (it
is one protocol + one callback channel), no `health` heartbeat (in-process; §13), no `detect_pane`
RPC (pane detection is by `process_names`; §6), no `prompt_user`, no separate `translate_event`
entry point (ingress calls `handleIngress` directly), no settings-schema RPC (settings are a typed
struct; §11), and no granular `update_session_status` / `request_notification` /
`dismiss_response_request` callbacks (every state change is one `emit(PluginEvent)`).
`deliverResponse` + `sendText`/`sendKeys` carry the response-form round-trip's delivery half.

### 4.1 Registry & dispatch

```swift
@MainActor
final class PluginRegistry {
    // Compile-time table: id → factory. Adding an agent edits exactly this.
    private let factories: [String: @Sendable () -> any PluginCore] = [
        "claude-code": { ClaudeCodePluginCore() },
        "codex":       { CodexPluginCore() },
    ]
    private(set) var active: [String: any PluginCore] = [:]   // enabled + initialized
}
```

The agent-blind core (`ClaudeSpyServerFeature`) owns the registry and the factory table; the
**dispatcher / runtime stays agent-neutral** — it only ever touches `any PluginCore` and
`PluginHost`. The factory table is the *only* place that names concrete agent types. This is what
delivers the v1 promise: the dispatcher, tmux layer, CLI, and iOS never switch on an agent.

A single `PluginEventDispatcher` consumes every `PluginEvent` (whether returned from
`handleIngress` or pushed via `host.emit`) and fans its fields out to the existing sinks: session
status, notifications, response requests, app actions. There is exactly one path.

## 5. The `PluginEvent` envelope — the single state-change carrier

Everything a plugin wants to change about app state travels as one envelope. There is no second
mechanism. The envelope:

```swift
public struct PluginEvent: Codable, Sendable, Equatable {
    public let pluginID: String
    public let sessionID: String
    public let working: Bool?          // nil = "no opinion, leave state alone"
    public let attention: Bool
    public let notification: NotificationSpec?      // pre-baked title + body
    public let responseRequest: ResponseRequestPayload?   // { requestID, request: AgentResponseRequest? }
    public let appActions: [AppAction]              // default []
    public let tmuxPane: String?       // from IngressContext; bootstraps AgentSession↔pane
    public let projectPath: String?    // from IngressContext; sidebar project name pre-refresh
}
```

- `working` / `attention` drive `AgentSession` status, forwarded to iOS as `agent_session_status`.
- `notification` — the core formats the strings; the app surfaces a Mac notification AND pushes to iOS.
- `responseRequest` — set when the event needs an iOS form (§7); the app correlates `requestID`.
- `appActions` — discrete agent-blind Mac triggers (§6).
- `tmuxPane` / `projectPath` — stamped from `IngressContext` so the app can bootstrap an
  `AgentSession`↔pane mapping and render the project name before any tmux refresh tick.

**Retraction.** `ResponseRequestPayload.request` is **optional** — `{ requestID, request:
AgentResponseRequest? }`. The dispatcher reads three states off a `PluginEvent`:

| `responseRequest` | `.request` | Meaning |
|---|---|---|
| `nil` | — | no response activity this event |
| non-`nil` | non-`nil` | **open** the form for `requestID` |
| non-`nil` | `nil` | **retract** the form with `requestID` |

The Mac forwards `agent_response_request` with `request: null` for the retract case — which is
already exactly what the iOS wire expects (§7.2). This keeps retraction on the single envelope: there
is **no** separate `dismiss_response_request` callback. (A plugin retracts when the agent advanced on
its own, or the user answered on the Mac side first.)

## 6. App actions & yolo

`AppAction` is the closed, agent-blind vocabulary of Mac-side feature triggers a plugin can fire:

```swift
public enum AppAction: Codable, Sendable, Equatable {
    case openFileSuggestion(sessionId: String, path: String, displayName: String, isPlan: Bool)
    case dismissFileSuggestions(sessionId: String)
    case sessionEnded(sessionId: String, closePaneEligible: Bool)
}
```

- `openFileSuggestion` — the core saw a Write to a `.md`/`.markdown` path; the app surfaces an
  "open this file?" prompt.
- `dismissFileSuggestions` — clear outstanding suggestions (on prompt submit).
- `sessionEnded` — the core signals a session end (any reason). The app resets the pane's
  session-scoped state — notably yolo mode, so a fresh session on the same pane doesn't inherit it
  (context compaction sends no SessionEnd, so yolo survives a compaction restart). When
  `closePaneEligible` is true (the agent exited cleanly at the prompt) the app additionally closes
  the pane **iff** the user's `closePaneOnSessionEnd` preference is on. The app owns yolo and the
  pref; the core only states intent + close-eligibility.

**Yolo auto-approve is not an AppAction.** It is `PermissionRequest.isAutoApprovable: Bool`. When
the app receives a `responseRequest: .permission` with `isAutoApprovable == true` for a pane in
yolo mode, it immediately calls `deliverResponse(... .permission(.allow))` on the core — no iOS
form shown. The core never knows about yolo; it only states safety.

**Pane detection** is by manifest `process_names` only: `TmuxService.detectAgentPanes(...)` walks
each pane's process tree for descendants matching any enabled plugin's `process_names`. There is no
`detect_pane` RPC in v1 (both bundled agents are detected by name; rich detection is a v2 hook).

## 7. iOS surface

iOS stays entirely plugin-blind: it renders native SwiftUI from a closed, app-defined wire format
and never learns which plugins the Mac has loaded.

### 7.1 Closed response vocabulary

iOS understands a closed 5-case enum. Cores translate their agent-specific events into one of
these; anything outside the set stays Mac-only (no iOS form):

```swift
public enum AgentResponseRequest: Codable, Sendable, Equatable {
    case prompt(PromptRequest)                  // free-text input
    case replyAfterStop(ReplyAfterStopRequest)  // reply after the agent stops
    case permission(PermissionRequest)          // approve/deny (+ isAutoApprovable, suggestions)
    case askUserQuestion(AskUserQuestionRequest)// 1+ questions, multi-select, free-text "Other"
    case approvePlan(ApprovePlanRequest)        // approve/reject (+ optional edit)
}
```

Paired responses iOS sends back (`AgentResponse`): `prompt(text)`, `replyAfterStop(text)` (empty
string = "send nothing, just interrupt"), `permission(decision, appliedSuggestionId?)`,
`askUserQuestion([QuestionAnswer])`, `approvePlan(decision, editedPlan?)`. iOS sends **structured**
choices; the **core** translates them into agent keystrokes/HTTP/etc. iOS never builds
agent-specific keystrokes.

`description` and any formatted strings are rendered **Mac-side by the core**; iOS just displays.

### 7.2 Wire messages (Mac → iOS / iOS → Mac)

- `agent_session_status { session_id, plugin_id, working, attention, timestamp }` — high-frequency
  badge updates. No fields, no tool name, no card.
- `agent_response_request { session_id, plugin_id, request_id, request: AgentResponseRequest? }` —
  `request: null` retracts an open form.
- `agent_response_submission { session_id, plugin_id, request_id, response: AgentResponse }` — the
  Mac matches `request_id` and calls `core.deliverResponse(...)`.
- `plugin_presentations { presentations: [{ id, version, display_name, short_name, color, icon_b64 }] }`
  — pushed on every viewer connect and on enable/disable/upgrade. **Always the complete enabled set.**
- **Project list** is *not* a new plugin message — it reaches iOS via the existing
  `SessionStateMessage.claudeProjects` (`[AgentProject]`, each tagged by `pluginID`). `host.setProjects`
  populates the host's project model and that pre-existing message carries it to iOS unchanged; iOS
  looks up the sidebar icon/name from the presentation cache by `pluginID`.

### 7.3 Presentation cache — in-memory only

iOS holds presentations in an **in-memory** dictionary keyed by plugin id and **full-replaces** on
each `plugin_presentations` push. Because the Mac re-pushes the complete set on every viewer
connect, iOS never persists to disk — a disk cache would only save the sub-second flash on
reconnect, at the cost of a load race against the incoming push. Not worth it.

### 7.4 What does not exist on iOS

No `EventRowView`, no `HookAction`/`HookEvent` decoding, no `KeystrokeBuilder`/per-tool keystroke
construction, no per-plugin settings UI (read-only "Configured by Mac"), no schemas of any kind.

## 8. Ingress

The app owns **one** Unix socket at `~/.gallager/state/ingress.sock` (one socket for all plugins,
not one per plugin). Each frame self-identifies with a `plugin_id`. The frame:

```
4-byte big-endian UInt32 length + JSON body
body = { "plugin_id": "<id>", "context": { <env vars> }, "payload": <raw host-agent event> }
```

`context` is the env snapshot the bridge harvested (`TMUX_PANE` always; agent-specific keys like
`CLAUDE_PROJECT_DIR` read via per-agent `IngressContext` extensions). The app reads a frame, routes
by `plugin_id` to the owning core's `handleIngress(frame)`, and dispatches the returned event.
Frames for disabled/unknown plugins are dropped with a debug log.

### 8.1 Hook bridges register at install, not launch

**Critical correctness point.** Ingress must work for agents the user launches **manually** in a
pane Gallager did not start. So the socket path is **not** injected at agent launch. Instead,
`core.install()` registers the hook bridge **once** into the host agent's own hook config, and the
installed hook command **bakes in** (a) this plugin's `plugin_id` and (b) the well-known socket
path (`~/.gallager/state/ingress.sock`, or the same `GALLAGER_SOCK`-style discovery the CLI uses).
The bridge then fires for *any* session of that agent — Gallager-launched or not — opens the
socket, writes one self-identifying frame, and exits. Pane identity comes from `TMUX_PANE` in the
bridge's env.

The bridge stays **language-agnostic** (e.g. a small `hook.py`). It is dead-simple: read stdin, read
a couple of env vars, connect, write one length-prefixed frame, exit. This contract is durable and
shared with v2.

### 8.2 No offline buffering

If Gallager isn't running, the socket doesn't exist; the bridge gets a connect error and exits
non-zero; the event drops. No queue, no fallback. Gallager observes sessions while it's open; it is
not a retroactive monitor.

### 8.3 Backpressure

If the app is slow to accept, the bridge's host-agent-imposed hook timeout fires and the agent
moves on; the bridge exits non-zero. A malformed frame is logged and dropped; the socket stays
alive for the next frame.

## 9. On-disk layout

```
Gallager.app/Contents/Resources/plugins/   ← bundled, immutable, ships with app
  claude-code/
    plugin.json                            ← minimal manifest (§10)
    assets/icon.png                        ← presentation icon
  codex/                                   ← same shape
                                           (no bin/ — cores are compiled into the app)

~/.gallager/
  registry.json                            ← canonical installed-plugin list (all source:"bundled")
  state/
    ingress.sock                           ← THE app-owned ingress socket (one, not per-plugin)
    plugins/<id>/
      settings.json                        ← user settings for this plugin
      logs/sidecar.log                     ← rotated 5 MB max (the core's log() sink)
      cache/  db/                          ← per-plugin scratch
```

`~/.gallager/plugins/` (user-installed, hot-swappable) is **reserved for v2** — v1 has no loader
for a folder-dropped plugin because v1 plugins are compiled in. v1 ignores that directory.

## 10. Manifest (minimal v1)

For compile-time-known plugins the manifest only needs to seed the presentation and pane detection.
The remaining fields below are v2 forward-compat room the v1 runtime does not read.

```json
{
  "schema_version": 1,
  "id": "claude-code",
  "display_name": "Claude Code",
  "short_name": "Claude",
  "version": "1.0.0",
  "process_names": ["claude"],
  "ui": { "icon": "assets/icon.png", "color": "#cb6f3a" }
}
```

**`runtime` is read in v1** (not merely reserved). v1 defines `enum Runtime { case inProcess, sidecar }`,
defaulting to `.inProcess` when the field is absent or `null`. In v1 it is *always* `.inProcess`; the
registry's `makeCore` switches on it (v2 adds the `.sidecar` arm — companion spec §2). Defining the
enum and its decode now means v2 introduces **no** decode-semantics shift at the seam.

**`ui.color`** is the presentation accent color (hex). The Mac sources the presentation color from
the manifest, falling back to `#888888` when the field is absent.

**Reserved for v2 (the v1 runtime ignores if present):** `sidecar`, `manifest_url`, `bundle_url`,
`bundle_sha256`, `publisher`, `capabilities`, `signature`. Keeping them reserved means v2 requires no
manifest schema bump.

## 11. Settings

Per-plugin settings are a **typed Swift struct** in each core, Codable to `settings.json` at the
existing path with snake_case keys:

```swift
struct ClaudeCodeSettings: Codable, Sendable {
    var commandPath: String = "claude"   // command_path
    var autoRun: Bool = true             // auto_run — gates command_for_launch
    var logLevel: LogLevel = .info        // log_level
}
```

The Mac renders one **hand-written** `PluginSettingsForm` that switches on `pluginID` to bind the
concrete controls (TextField / Toggle / segmented Picker). No JSON-schema interpreter, no dynamic
field-type table. `applySettings` keeps two-phase validation (UI rejects malformed input; the core
does semantic validation, e.g. "does this binary launch?", and may return `.error`). iOS stays
read-only "Configured by Mac".

**Initial value vs. edits.** `PluginEnv.settings` (the current `settings.json` bytes) is the
**authoritative initial value** the core decodes during `initialize`. The app does **not** call
`applySettings` immediately after `initialize`; `applySettings` fires only on a subsequent user edit.
So there is one initial-load path (`PluginEnv.settings`) and one update path (`applySettings`).

A one-shot migration on first launch of the new version reads the legacy
`AppSettings.claudeCommandPath` / `codexCommandPath` from `UserDefaults`, writes them as typed
`command_path` into the two `settings.json` files, and removes the old keys. (Small, typed — no
schema generality.)

To couple cleanly: the two `Settings` structs live where both the core and the Mac form can see
them (the per-agent core modules, with `ClaudeSpyServerFeature` importing them, or a shared
settings module if that import is undesirable).

## 12. Project & session lifecycle

- **Projects are push-based.** On `initialize`, each core does an initial scan and calls
  `host.setProjects`. Each core picks its own refresh strategy (Claude/Codex: FSEvents watcher on
  `~/.claude/projects/` / `~/.codex/sessions/`, debounced rescan + `setProjects`; no polling). The
  app never asks "what are your projects?"; it consumes `setProjects` and shows what arrives. The
  manual refresh button calls `core.refreshProjects()` on every active core.
- **Stale beats empty.** The app keeps the last `setProjects` list visible until a fresh one
  arrives (e.g. across a settings re-apply). Never blank the sidebar.
- **Auto-launch.** When the user opens a project and the plugin's `autoRun` is on, the app calls
  `core.commandForLaunch(projectPath:)` and starts the agent in a tmux pane. Commands and args are
  shell-quoted by the app before `tmux send-keys`.
- **Codex pane↔session correlation.** `CodexPluginCore` keeps its existing correlation file at
  `~/.claudespy/codex-sessions/<tmux_pane>.json` (written on session start) to map Codex session
  ids to panes. This is core-internal; the app doesn't know about it.

## 13. Crash model (v1: accepted)

Because plugins run in-process, **v1 has no crash isolation and that is an accepted non-goal.**

- A **trap** in a core (force-unwrap, precondition, fatalError, out-of-bounds) crashes Gallager.
  This is treated as a first-party app bug and fixed in the core — the same standard as any app
  code. The scanners (which parse real-world `~/.claude.json` / rollout files) are the highest-risk
  surface; they MUST be written defensively (no force-unwrap on parsed data, `do/try/catch` around
  decode, skip-and-log malformed entries). **If hardening the scanners against hostile on-disk data
  proves impractical, that is the trigger to adopt v2's out-of-process tier for those plugins.**
- A **thrown** Swift error from any `PluginCore` method is caught at the dispatch boundary, logged
  via the plugin's log file, and swallowed (the operation no-ops). It does not crash the app.
- **failed-init:** if `initialize` throws, the plugin is left disabled, an error banner shows in
  Settings, and there is no auto-retry — the user re-enables to retry.

There is no `SidecarSupervisor`, restart/backoff policy, crash-loop-disable, or 30s heartbeat in
v1. (All of that is v2, where it becomes meaningful because there is a child process to restart.)

## 14. `gallager plugin` CLI (v1 verbs)

| Command | Description |
|---|---|
| `gallager plugin list [--json]` | id, version, enabled, source (all `bundled` in v1). |
| `gallager plugin info <id> [--json]` | manifest, state-dir size, log path, enabled / failed-init state. |
| `gallager plugin enable <id>` | construct + initialize the core. |
| `gallager plugin disable <id>` | `shutdown()` the core; leaves files. |
| `gallager plugin logs <id> [-f] [--lines N]` | print/tail the plugin's log file. |
| `gallager plugin call <id> <method> [<json>]` | direct debugging dispatch into the in-process core. |

`install` / `remove` / `update` are **v2** (there is nothing to install/remove/update in v1).
Existing conventions (socket discovery, `--json`, exit codes 0/1/2) are unchanged.

## 15. Per-plugin log viewer

Settings → Plugins → `<id>` → **View Logs** opens a sheet with a monospaced `ScrollView` of the
file's last 256 KB (head-truncated), `DispatchSource` auto-tail, and Show-in-Finder / Copy-All /
Clear actions. The log file is the `host.log()` sink, size-rotated at 5 MB. ~150 LOC, one view.

## 16. Extraction & rollout

This lands as a single flag-day PR.

**Deleted outright:** `CodingAgent` enum; `HookServerService` + `~/.claudespy-port`; `HookEvent`,
`HookAction`, all `*Body` structs, `CommonHookFields`; the iOS `EventRowView` + `HookAction`/
`HookEvent` decode paths + `AskUserQuestionKeystrokes`; all `case .claudeCode:`/`case .codex:`
switches across `AppCoordinator`/`Settings`/`MainView`/`TmuxService`; the repo-root `plugin/`
folders (relocate into `Resources/plugins/<id>/`); hardcoded `"Claude Code"` notification copy.

**Renamed:** `ClaudeSession` → `AgentSession` (`agent: CodingAgent` → `pluginID: String`; status as
plain `Bool`s; the trailing-5 `events:[HookEvent]` buffer dropped). `ClaudeProjectInfo` →
`AgentProject` (`agent` → `pluginID`). `claudePanes`/`hasClaudeSession`/`detectClaudePanes` →
`agentPanes`/`hasAgentSession`/`detectAgentPanes`.

**Moved into cores:** scanners, installers, binary locators, the markdown-write inspection, the
notification copy, the 30→5 event mapping.

**The per-event behavioral contract lives in each plugin core, not here.** Which status bits a given
host-agent event sets, the exact notification copy, which event dispatches to `.permission` vs
`.askUserQuestion` vs `.approvePlan`, and which events emit which `AppAction` — that mapping is
agent-specific and belongs to each `*PluginCore` translator. It MUST be documented in that plugin's
own doc (`docs/plugins/claude-code.md`, `docs/plugins/codex.md`) as the normative behavior spec for
that core; this system spec stays agent-blind and only defines the `PluginEvent` fields those
translators populate.

**Order of work:** (1) shared `ClaudeSpyNetworking` types (`AgentResponseRequest`, `AppAction`,
`PluginEvent`, presentation + status wire messages). (2) `GallagerPluginProtocol`: `PluginCore`,
`PluginHost`, `IngressFrame` (+ `plugin_id`), value types. (3) The agent-blind runtime: registry,
dispatcher, the one ingress `NWListener`, the `PluginHost` implementation, presentation push. (4)
`ClaudeCodePluginCore` + `CodexPluginCore` conforming to `PluginCore`. (5) Wire the registry into
`AppCoordinator`; replace agent switches with `pluginID` paths. (6) Settings migration. (7) Renames.
(8) iOS: delete the dead paths, reroute `ResponseViews/*` onto `AgentResponseRequest`, consume the
new wire messages. (9) Bump `VersionCompatibility`. (10) Tests (§17).

## 17. Testing

Three layers (the contract is process-agnostic, so most tests don't care about in-process vs v2):

1. **Unit/integration per `*PluginCore`** (Point-Free Dependencies, swift-testing): scanner /
   installer / event-translator / keystroke-builder logic. The bulk of each core. Highest value,
   unchanged by the process model.
2. **Contract tests in `GallagerPluginProtocol`**: a `MockPluginHost` drives a core; a test
   `EchoPluginCore` (an in-process `PluginCore` conformer built into the test target) exercises the
   dispatcher and the `PluginHost` callbacks.
3. **E2E in `ClaudeSpyE2ELib`**: the ingress path is covered end-to-end by the test driver writing
   self-identifying frames to the **app-owned socket** (the `macSendRawHookPayload` DSL step, now
   targeting `~/.gallager/state/ingress.sock` with a `plugin_id` field) → the app routes to
   `EchoPluginCore.handleIngress` → iOS observes `agent_session_status` / response forms /
   presentations. `--gallager-state-root` still isolates per-plugin state + the socket path per
   scenario. Response-form round-trips assert that `deliverResponse` reached the core AND that the
   core called `sendText`/`sendKeys` as configured.

Crash-restart / crash-loop-disable E2E scenarios are **v2** (no child process to crash in v1).

## 18. Non-goals (v1) — all are v2 capabilities the contract is designed for

- Out-of-process plugins, crash isolation, supervision/restart/backoff, heartbeat.
- Third-party plugins; URL distribution; in-app install/update/uninstall; hash pinning; trust
  prompt; signing; macOS App Sandbox / seatbelt confinement.
- Hot-reload without recompile (a new agent is a recompile in v1).
- Rich pane detection (`detect_pane` RPC).
- Sidecar-initiated modal prompts (`prompt_user`).
- Plugin-defined iOS UI of any kind.
- Offline hook handling.

## 19. The v1 → v2 seam (forward note)

v2 adds out-of-process third-party plugins **without changing anything in this document**. The
mechanism: `PluginRegistry` gains a second construction path — for a manifest declaring
`runtime: "sidecar"`, it constructs a `SidecarPluginCore` (a `PluginCore` conformer that spawns the
sidecar process and marshals each protocol method over a transport, translating inbound messages
into `PluginHost` callbacks) instead of looking up the compile-time factory. The dispatcher, the
one app-owned ingress socket, `PluginEvent`, `AgentResponseRequest`, the iOS surface, and the CLI
verbs are all untouched — the sidecar's bridge writes to the *same* app-owned socket, tagged with
its `plugin_id`. See the companion v2 spec.
