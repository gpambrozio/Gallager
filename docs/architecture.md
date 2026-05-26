# ClaudeSpy Mac App Architecture

ClaudeSpy is a native macOS application that mirrors tmux panes in dedicated windows, integrates with coding agents (Claude Code, OpenAI's Codex CLI) via a **plugin runtime**, and streams terminal data to paired iOS devices over encrypted WebSocket connections.

Coding-agent integration is implemented as a plugin system: each agent ships as a bundled plugin with its own sidecar process, supervised by the Mac app's `PluginManager`. Sessions and projects carry a `pluginID` so the same plumbing serves every agent. See the [Plugin Runtime](#plugin-runtime) section below, and the full spec at `docs/superpowers/specs/2026-05-24-coding-agent-plugin-system-design.md`.

## Component Overview

### Coordination

| Component | Type | Responsibility |
|-----------|------|----------------|
| **AppCoordinator** | `@Observable @MainActor` | Central service coordinator — creates, wires, and manages all services |

### Tmux Layer

| Component | Type | Responsibility |
|-----------|------|----------------|
| **TmuxService** | `@Observable @MainActor` | Abstracts all tmux CLI interactions — pane discovery, content capture, session creation |
| **TmuxControlClient** | `actor` | Control mode connection (`-f no-output`) for commands and event notifications |
| **TmuxControlClientManager** | `@Observable @MainActor` | Manages TmuxControlClient instances per tmux session (one client per session) |
| **PipePaneReader** | `actor` | Per-pane FIFO reader for raw PTY bytes via pipe-pane. One instance lives for the pane's full lifetime, with three internal modes (`scanOnly` → `buffering` → `live`) toggled by the manager |
| **PaneStreamManager** | `@Observable @MainActor` | Owns one `PipePaneReader` per known pane and multiplexes events to subscribers (mirror windows, iOS streaming). Conforms to `PipePaneReaderDelegate` |

### Window Management

| Component | Type | Responsibility |
|-----------|------|----------------|
| **MirrorWindowManager** | `@Observable @MainActor` | NSWindow lifecycle, hook event routing, session tracking |
| **DockIconManager** | `@MainActor` | Toggles dock icon visibility based on open windows |

### Remote Access (iOS Communication)

| Component | Type | Responsibility |
|-----------|------|----------------|
| **DeviceConnectionManager** | `@Observable @MainActor` | Manages connections to all paired iOS devices |
| **DeviceConnection** | `@Observable @MainActor` | WebSocket connection to a single paired iOS device |
| **PairingManager** | `@Observable @MainActor` | Device pairing flow — code generation, server registration, polling |
| **TerminalStreamService** | `@Observable @MainActor` | Batches and streams terminal data to iOS devices via DeviceConnectionManager |
| **TmuxCommandExecutor** | `actor` | Executes commands from iOS (keystrokes, cancel, session creation) |

### Plugin Runtime

| Component | Type | Responsibility |
|-----------|------|----------------|
| **PluginManager** | `@Observable @MainActor` | Discovers plugin bundles, supervises one `SidecarSupervisor` per enabled plugin, fans out events through the dispatcher, and routes responses back to the right sidecar |
| **PluginRegistry** | `actor` | Indexes plugins from bundled (`Gallager.app/Contents/Resources/plugins/`) and user (`~/.gallager/plugins/`) roots; loads each `plugin.json` manifest |
| **SidecarSupervisor** | `actor` | Spawns and respawns the sidecar process for one plugin, with crash-loop backoff (auto-disable after 4 crashes inside the window) |
| **JSONRPCConnection** | `actor` | Length-prefixed JSON-RPC framing over a sidecar's stdin/stdout; routes typed requests, notifications, and responses |
| **PluginEventDispatcher** | `@MainActor` | Fans `PluginEvent`s into the pane-state / session-state / notification / response-request sinks |
| **PluginRouter** | `@MainActor` | Resolves the owning sidecar for a `(session_id, request_id)` pair so iOS-originated `AgentResponse`s reach the right plugin |
| **AssetCache** | `actor` | Caches per-plugin presentation assets (icon PNGs, display strings) keyed by `(plugin_id, version)` for the `plugin_presentations` push |
| **IngressSocketServer** | `actor` | Per-plugin Unix-domain socket the sidecar uses to feed framed JSON events into the manager (replaces the legacy `/api/hooks` HTTP shim) |
| **TerminalLauncher** | `@MainActor` | Launches tmux sessions in external terminal apps (Terminal, iTerm2, Warp, etc.). The launch command for each plugin is resolved by asking the plugin's sidecar via `command_for_launch` |

### System Integration

| Component | Type | Responsibility |
|-----------|------|----------------|
| **SleepPreventionManager** | `@MainActor` | Prevents Mac sleep during active sessions via IOKit assertions |
| **LoginItemService** | `enum` (static) | Manages launch-at-login via SMAppService |
| **UpdaterController** | `@Observable @MainActor` | Wraps Sparkle updater for SwiftUI |

### Utilities

| Component | Type | Responsibility |
|-----------|------|----------------|
| **ProcessRunner** | `actor` | Executes external processes asynchronously |

## App Bootstrap

The app entry point (`TmuxPaneMirrorApp`) creates the coordinator and defines three scenes:

```
@main TmuxPaneMirrorApp
├── init() → LoggingConfiguration.bootstrap() → AppCoordinator()
├── Window("Panes") → ContentView + environment injection
├── Settings → SettingsView
└── MenuBarExtra → .task { coordinator.setupAllServices() }
```

**AppCoordinator** has a two-phase initialization:

1. **Synchronous (`init`)** — Creates core services that don't need async:
   TmuxService, TmuxControlClientManager, PaneStreamManager, MirrorWindowManager,
   TerminalStreamService, DockIconManager, SleepPreventionManager,
   E2EEService (from Keychain if available)

2. **Async (`setupAllServices`)** — Completes initialization requiring async work:
   E2EEService (if not loaded), PairingManager, DeviceConnectionManager,
   TmuxCommandExecutor, one-shot plugin settings migration, `PluginManager.start()`
   (which discovers bundles, spawns sidecars, and starts the per-plugin ingress sockets),
   auto-connect to paired devices, periodic session validation, system wake observer

## Service Wiring

AppCoordinator connects services via callbacks:

```
PluginManager events → MirrorWindowManager (session lifecycle, working/attention)
                    → DeviceConnectionManager (forward to paired iOS viewers)
                    → SleepPreventionManager.updateForSessionCount()
                    → NotificationCenter (per-plugin notification copy)

TmuxControlClientManager dimension changes → PaneStreamManager.updateDimensions(paneId:width:height:)
TmuxControlClientManager pane exits       → MirrorWindowManager.updatePaneStates()
                                          → TerminalStreamService.stopStreamsForClosedPanes()
                                          → SleepPreventionManager.updateForSessionCount()

TmuxService pane changes → DeviceConnectionManager.pushSessionStateToAll()

iOS commands → TmuxCommandExecutor.execute()
             → TerminalStreamService.startStreaming() / stopStreaming()

iOS AgentResponse submissions → PluginRouter → owning sidecar's `deliver_response`

System wake → DeviceConnectionManager.reconnectAllImmediately()
```

## Data Flow: Tmux Output to Terminal Display

```
tmux session
    │
    ├── tmux -C attach -f no-output,ignore-size (control mode: commands + events only)
    │
    ├── pipe-pane -O "cat > /tmp/claudespy-pipe-<id>.fifo" (raw PTY bytes)
    │
    ▼
PipePaneReader (actor, one per pane)
    │ Reads raw bytes from FIFO, filters tmux title sequences,
    │ parses OSC notification/title/clipboard/progress events,
    │ and forwards via PipePaneReaderDelegate
    │
    ▼
PaneStreamManager (delegate + multiplexer)
    │ Routes events to subscribers, owns reader lifecycle
    │
    ├──→ Mirror Window (SwiftTerm) — immediate display
    │
    └──→ TerminalStreamService — batches (8KB / 50ms)
              │
              ▼
         DeviceConnectionManager.sendTerminalStreamToAll()
              │ WebSocket per device, E2EE encrypted
              │
              ▼
         Relay Server → iOS devices
```

## Plugin Runtime

Gallager's agent support is implemented as a plugin system. The Mac
app supervises one sidecar process per enabled plugin via the
`ClaudeSpyPluginRuntime.PluginManager`. Plugins implement a JSON-RPC
protocol (`GallagerPluginProtocol`); see the spec at
`docs/superpowers/specs/2026-05-24-coding-agent-plugin-system-design.md`
for full details.

Bundled plugins (Claude Code, Codex) ship under
`Gallager.app/Contents/Resources/plugins/<id>/`. User-installed plugins
land in `~/.gallager/plugins/<id>/`. Both have the same on-disk shape.

iOS knows nothing about the plugin system itself: it consumes
`agent_session_status` and `agent_response_request` wire messages plus
per-plugin presentation bundles (`plugin_presentations`) and renders
SwiftUI forms from a closed-set `AgentResponseRequest` enum (Spec §7.2).

### Plugin Event Flow

```
host agent (Claude Code / Codex / …)
    │ writes a hook payload to the bridge entry point
    ▼
Plugin sidecar (per-plugin executable, e.g. ClaudeCodePluginSidecar)
    │ translates the agent-specific payload into a PluginEvent
    │ (status update, response request, notification, project push, …)
    ▼
IngressSocketServer (per-plugin Unix socket, replaces the legacy /api/hooks HTTP shim)
    │ frames the event as length-prefixed JSON-RPC
    ▼
PluginManager → PluginEventDispatcher (@MainActor)
    │
    ├──→ MirrorWindowManager + AgentSession store
    │       session_start → open mirror window
    │       agent_session_status → update working/attention badges
    │
    ├──→ DeviceConnectionManager
    │       agent_session_status / agent_response_request → forwarded
    │       to paired iOS viewers as wire messages (E2EE encrypted)
    │
    ├──→ NotificationCenter
    │       pre-baked title + body strings from the sidecar
    │
    └──→ SleepPreventionManager.updateForSessionCount()
```

When iOS replies to an `agent_response_request`, the `PluginRouter`
matches `(session_id, request_id)` to the owning sidecar and calls
`deliver_response` on it; the sidecar then converts the structured
`AgentResponse` into whatever its host agent expects (keystrokes,
HTTP, MCP, etc.). iOS never builds agent-specific payloads.

## Multi-Device Terminal Streaming

Multiple iOS devices can watch the same pane simultaneously:

- **TerminalStreamService** uses reference counting (`deviceSubscriberCount` per stream)
- First subscriber creates the PaneStreamManager subscription, which switches the per-pane reader from scan-only into live mode
- Additional subscribers reuse the existing stream and receive current content
- Each `stopStreaming` decrements the count; the manager subscription is dropped when count reaches 0, returning the reader to scan-only mode (it stays attached to the FIFO for the pane's full lifetime)
- System-level cleanups (`stopAllStreams`, `stopStreamsForClosedPanes`) use `force: true` to bypass count

**ConnectedViewerManager** broadcasts to all connected devices:
- `sendAgentSessionStatusToAll()` — per-session working/attention updates
- `sendAgentResponseRequestToAll()` — interactive response requests for iOS forms
- `sendTerminalStreamToAll()` — terminal data
- `pushSessionStateToAll()` — full session state sync (on connect, session metadata changes)

See `docs/streaming-architecture.md` for the full streaming data flow.

## Concurrency Model

```
@MainActor (UI thread)                    Actor-Isolated (background)
─────────────────────                    ─────────────────────────────
TmuxService                              ProcessRunner
PaneStreamManager                        TmuxControlClient
MirrorWindowManager                      PipePaneReader
TerminalStreamService                    TmuxCommandExecutor
PluginManager                            SidecarSupervisor
PluginEventDispatcher                    JSONRPCConnection
PluginRouter                             IngressSocketServer
DeviceConnectionManager                  PluginRegistry
DeviceConnection                         AssetCache
PairingManager
AppCoordinator
AppSettings
DockIconManager
SleepPreventionManager
All SwiftUI Views
```

- All UI-bound services are `@MainActor` isolated
- I/O and process work runs in dedicated actors
- Cross-isolation uses async/await exclusively (no GCD)
- All types crossing isolation boundaries are `Sendable`

## File Structure

```
ClaudeSpyPackage/Sources/
├── ClaudeSpyServerFeature/        # Mac app: coordinator + services + views
│   ├── Coordinators/              # AppCoordinator + plugin-aware routers
│   ├── Managers/                  # MirrorWindowManager (+PluginSinks), DockIconManager, …
│   ├── Models/                    # PaneInfo, Settings
│   ├── Services/                  # tmux, streaming, pairing, layout, file system
│   └── Views/                     # SwiftUI views (settings, terminal, file browser, …)
├── GallagerPluginProtocol/        # Plugin manifests, JSON-RPC framing, event/response types
├── ClaudeSpyPluginRuntime/        # Mac-only: PluginManager, PluginRegistry, SidecarSupervisor,
│                                  # IngressSocketServer, PluginEventDispatcher, PluginRouter,
│                                  # AssetCache, PluginSettingsMigration
├── ClaudeCodePluginCore/          # Claude Code agent: scanner, locator, installer, hook translator
├── ClaudeCodePluginSidecar/       # Claude Code sidecar executable (target: gallager-plugin-claude-code)
├── CodexPluginCore/               # Codex agent: scanner, installer, hook translator
├── CodexPluginSidecar/            # Codex sidecar executable
└── EchoPluginSidecar/             # Test fixture (E2E only, not shipped)

ClaudeSpyPackage/PluginBundles/
├── claude-code/                   # Bundled plugin: plugin.json + assets + agent-bundle (hooks.json, scripts)
└── codex/                         # Bundled plugin

Gallager.app/Contents/Resources/plugins/<id>/   # Build-time copy of PluginBundles entries
~/.gallager/plugins/<id>/                       # Runtime root for user-installed plugins (same on-disk shape)
~/.gallager/state/plugins/<id>/                 # Per-plugin settings.json, sidecar.log
```
