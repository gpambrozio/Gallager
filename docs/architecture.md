# ClaudeSpy Mac App Architecture

ClaudeSpy is a native macOS application that mirrors tmux panes in dedicated windows, integrates with **Claude Code and OpenAI's Codex CLI** via HTTP hooks, and streams terminal data to paired iOS devices over encrypted WebSocket connections.

Coding-agent integration is gated by a `CodingAgent` enum (`.claudeCode` / `.codex`) in `ClaudeSpyNetworking`. Every hook event, session, and project info value carries an `agent` field so the same plumbing serves both backends; the only agent-specific code lives in the project scanners, plugin/hook installers, and command-path resolution.

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

### Hook Integration

| Component | Type | Responsibility |
|-----------|------|----------------|
| **HookServerService** | `actor` | HTTP server (dynamic port) receiving hook events from Claude Code and Codex CLI. The `agent` query param (default `.claudeCode`) tags every incoming event |

### Coding-Agent Integration

| Component | Type | Responsibility |
|-----------|------|----------------|
| **PluginService** | `@Observable @MainActor` | Manages the Claude Code plugin (detection + bundled install) |
| **CodexPluginInstaller** | `struct` (Dependency) | Installs/uninstalls the bundled `gallager` Codex plugin via `codex plugin` commands so Codex forwards hooks to the local hook server |
| **ClaudeProjectScanner** | `actor` | Scans `~/.claude.json` to discover Claude Code projects |
| **CodexProjectScanner** | `struct` (Dependency) | Walks `~/.codex/sessions/**/rollout-*.jsonl` (honoring `CODEX_HOME`), reads each rollout's session-meta header to recover `cwd`, and groups by working directory |
| **ClaudePathDetector** | `enum` (static) | Detects the `claude` CLI path for auto-running in new sessions |
| **TerminalLauncher** | `@MainActor` | Launches tmux sessions in external terminal apps (Terminal, iTerm2, Warp, etc.) |

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
   TerminalStreamService, HookServerService, ClaudeProjectScanner, CodexProjectScanner,
   DockIconManager, SleepPreventionManager, PluginService, CodexPluginInstaller,
   E2EEService (from Keychain if available)

2. **Async (`setupAllServices`)** — Completes initialization requiring async work:
   E2EEService (if not loaded), PairingManager, DeviceConnectionManager,
   TmuxCommandExecutor, hook server start, auto-connect to paired devices,
   periodic session validation, system wake observer

## Service Wiring

AppCoordinator connects services via callbacks:

```
HookServerService events → MirrorWindowManager.handleHookEvent()
                         → DeviceConnectionManager.sendHookEventToAll()
                         → SleepPreventionManager.updateForSessionCount()

TmuxControlClientManager dimension changes → PaneStreamManager.updateDimensions(paneId:width:height:)
TmuxControlClientManager pane exits       → MirrorWindowManager.updatePaneStates()
                                          → TerminalStreamService.stopStreamsForClosedPanes()
                                          → SleepPreventionManager.updateForSessionCount()

TmuxService pane changes → DeviceConnectionManager.pushSessionStateToAll()

iOS commands → TmuxCommandExecutor.execute()
             → TerminalStreamService.startStreaming() / stopStreaming()

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

## Hook Event Flow

```
Claude Code / Codex CLI → POST localhost:<port>/api/hooks?tmux_pane=main:0.1&agent=claude-code|codex
    │
    ▼
HookServerService (actor)
    │ Parses JSON, creates HookEvent (tagged with `agent`, default `.claudeCode`)
    │
    ▼
AppCoordinator event handler
    │
    ├──→ MirrorWindowManager.handleHookEvent()
    │       SessionStart → add to activeSessions, open mirror window
    │       SessionEnd   → remove from activeSessions, close window
    │
    ├──→ DeviceConnectionManager.sendHookEventToAll()
    │       Forwards to all connected iOS devices (E2EE encrypted)
    │
    └──→ SleepPreventionManager.updateForSessionCount()
```

The same bridge script (`plugin/gallager/scripts/hook.py`) backs both agents. Claude Code calls it from `~/.claude/plugins/.../hooks.json` (the bundled Claude plugin); Codex calls it from `~/.codex/plugins/.../hooks.json` after `CodexPluginInstaller` registers the bundled `gallager` marketplace and installs the plugin via `codex plugin install`. The script appends `?agent=codex` to the POST when invoked by Codex so the server can tag the event correctly. Notification copy is rendered against `agent.displayName` / `shortName` so toasts read "Claude" or "Codex" as appropriate.

## Multi-Device Terminal Streaming

Multiple iOS devices can watch the same pane simultaneously:

- **TerminalStreamService** uses reference counting (`deviceSubscriberCount` per stream)
- First subscriber creates the PaneStreamManager subscription, which switches the per-pane reader from scan-only into live mode
- Additional subscribers reuse the existing stream and receive current content
- Each `stopStreaming` decrements the count; the manager subscription is dropped when count reaches 0, returning the reader to scan-only mode (it stays attached to the FIFO for the pane's full lifetime)
- System-level cleanups (`stopAllStreams`, `stopStreamsForClosedPanes`) use `force: true` to bypass count

**DeviceConnectionManager** broadcasts to all connected devices:
- `sendHookEventToAll()` — hook events
- `sendTerminalStreamToAll()` — terminal data
- `pushSessionStateToAll()` — session state sync

See `docs/streaming-architecture.md` for the full streaming data flow.

## Concurrency Model

```
@MainActor (UI thread)                    Actor-Isolated (background)
─────────────────────                    ─────────────────────────────
TmuxService                              ProcessRunner
PaneStreamManager                        TmuxControlClient
MirrorWindowManager                      PipePaneReader
TerminalStreamService                    TmuxCommandExecutor
                                         HookServerService
                                         ClaudeProjectScanner
                                         CodexProjectScanner
DeviceConnectionManager
DeviceConnection
PairingManager
AppCoordinator
AppSettings
DockIconManager
SleepPreventionManager
PluginService
All SwiftUI Views
```

- All UI-bound services are `@MainActor` isolated
- I/O and process work runs in dedicated actors
- Cross-isolation uses async/await exclusively (no GCD)
- All types crossing isolation boundaries are `Sendable`

## File Structure

```
ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/
├── Coordinators/
│   └── AppCoordinator.swift           # Central service coordinator
├── Hooks/
│   ├── HookModels.swift               # Event types, ToolInput enum
│   └── HookServerService.swift        # HTTP server (dynamic port)
├── Managers/
│   ├── DockIconManager.swift          # Dock icon visibility
│   ├── MirrorWindowManager.swift      # Window lifecycle
│   └── SleepPreventionManager.swift   # IOKit sleep prevention
├── Models/
│   ├── PaneInfo.swift                 # Tmux pane representation
│   └── Settings.swift                 # AppSettings, PairedDevice
├── Services/
│   ├── ClaudePathDetector.swift       # Claude CLI path detection
│   ├── ClaudeProjectScanner.swift     # Project discovery from ~/.claude.json
│   ├── CodexProjectScanner.swift      # Project discovery from ~/.codex/sessions/**/rollout-*.jsonl
│   ├── CodexPluginInstaller.swift     # Bundled `gallager` Codex plugin install/uninstall via `codex plugin`
│   ├── DeviceConnection.swift         # Single iOS device WebSocket
│   ├── DeviceConnectionManager.swift  # Multi-device coordinator
│   ├── ExternalServerClient.swift     # Legacy single-device client
│   ├── LoginItemService.swift         # Launch at login (SMAppService)
│   ├── PairingManager.swift           # Device pairing flow
│   ├── PaneStreamManager.swift        # Per-pane reader lifecycle + multi-subscriber multiplexer
│   ├── PipePaneReader.swift           # Per-pane FIFO reader (one per pane, scanOnly/buffering/live modes)
│   ├── PluginService.swift            # Claude Code plugin management (bundled plugin install)
│   ├── StreamState.swift              # View-side connection state enum
│   ├── TerminalLauncher.swift         # External terminal app integration
│   ├── TerminalStreamService.swift    # iOS streaming with batching
│   ├── TmuxCommandExecutor.swift      # Remote command execution
│   ├── TmuxControlClient.swift        # tmux control mode connection
│   ├── TmuxControlClientManager.swift # Control client per session
│   ├── TmuxService.swift              # Tmux CLI abstraction
│   └── UpdaterController.swift        # Sparkle updater wrapper
├── Utilities/
│   ├── NotificationNames.swift        # NotificationCenter names
│   └── ProcessRunner.swift            # Process execution
├── Views/
│   ├── CheckForUpdatesView.swift      # Sparkle update UI
│   ├── InteractiveTerminalView.swift  # Interactive terminal (SwiftTerm)
│   ├── LaunchAtLoginPromptView.swift  # Login item prompt
│   ├── MainView.swift                 # Pane list
│   ├── MenuBarExtraView.swift         # Menu bar dropdown
│   ├── MirrorWindowView.swift         # Mirror window display
│   ├── PaneListView.swift             # Pane list items
│   ├── PluginSettingsView.swift       # Plugin settings
│   ├── PluginSetupView.swift          # First-launch plugin setup
│   ├── CodexPluginInstallerRow.swift  # Codex CLI plugin install/uninstall row (Settings)
│   ├── RemoteAccessSettingsView.swift # Pairing & connection UI
│   ├── SettingsView.swift             # Settings tabs
│   └── TerminalContainerView.swift    # SwiftTerm bridge
└── ContentView.swift                  # Root view
```
