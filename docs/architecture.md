# ClaudeSpy Mac App Architecture

ClaudeSpy is a native macOS application that mirrors tmux panes in dedicated windows, integrates with Claude Code via HTTP hooks, and streams terminal data to paired iOS devices over encrypted WebSocket connections.

## Component Overview

### Coordination

| Component | Type | Responsibility |
|-----------|------|----------------|
| **AppCoordinator** | `@Observable @MainActor` | Central service coordinator — creates, wires, and manages all services |

### Tmux Layer

| Component | Type | Responsibility |
|-----------|------|----------------|
| **TmuxService** | `@Observable @MainActor` | Abstracts all tmux CLI interactions — pane discovery, content capture, session creation |
| **TmuxControlClient** | `actor` | Maintains long-lived `tmux -C attach` process, parses control mode events |
| **TmuxControlClientManager** | `@Observable @MainActor` | Manages TmuxControlClient instances per tmux session (one client per session) |
| **PaneStream** | `@Observable @MainActor` | Manages streaming connection lifecycle for a single pane |
| **PaneStreamManager** | `@Observable @MainActor` | Multiplexes streams to subscribers (mirror windows, iOS streaming) |

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
| **HookServerService** | `actor` | HTTP server (port 6111) receiving Claude Code hook events |

### Plugin & Claude Integration

| Component | Type | Responsibility |
|-----------|------|----------------|
| **PluginService** | `@Observable @MainActor` | Manages Claude Code plugin detection and installation |
| **ClaudeProjectScanner** | `actor` | Scans `~/.claude.json` to discover Claude Code projects |
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
   TerminalStreamService, HookServerService, ClaudeProjectScanner, DockIconManager,
   SleepPreventionManager, PluginService, E2EEService (from Keychain if available)

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

TmuxControlClientManager dimension changes → PaneStreamManager.updateDimensions()
TmuxControlClientManager pane exits       → MirrorWindowManager.cleanupStaleSessions()
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
    ├── tmux -C attach (control mode)
    │
    ▼
TmuxControlClient (actor)
    │ Parses %output events, unescapes octal, buffers split UTF-8
    │
    ▼
TmuxControlClientManager
    │ Routes to registered pane handlers
    │
    ▼
PaneStream (per-pane lifecycle)
    │ onData callback
    │
    ▼
PaneStreamManager (multiplexer)
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
Claude Code → POST localhost:6111/api/hooks?tmux_pane=main:0.1
    │
    ▼
HookServerService (actor)
    │ Parses JSON, creates HookEvent
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

## Multi-Device Terminal Streaming

Multiple iOS devices can watch the same pane simultaneously:

- **TerminalStreamService** uses reference counting (`deviceSubscriberCount` per stream)
- First subscriber creates the PaneStreamManager subscription
- Additional subscribers reuse the existing stream and receive current content
- Each `stopStreaming` decrements the count; stream only stops when count reaches 0
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
PaneStream                               TmuxControlClient
PaneStreamManager                        TmuxCommandExecutor
MirrorWindowManager                      HookServerService
TerminalStreamService                    ClaudeProjectScanner
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
│   └── HookServerService.swift        # HTTP server (port 6111)
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
│   ├── DeviceConnection.swift         # Single iOS device WebSocket
│   ├── DeviceConnectionManager.swift  # Multi-device coordinator
│   ├── ExternalServerClient.swift     # Legacy single-device client
│   ├── LoginItemService.swift         # Launch at login (SMAppService)
│   ├── PairingManager.swift           # Device pairing flow
│   ├── PaneStream.swift               # Single pane stream lifecycle
│   ├── PaneStreamManager.swift        # Multi-subscriber stream multiplexer
│   ├── PluginService.swift            # Claude Code plugin management
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
│   ├── RemoteAccessSettingsView.swift # Pairing & connection UI
│   ├── SettingsView.swift             # Settings tabs
│   └── TerminalContainerView.swift    # SwiftTerm bridge
└── ContentView.swift                  # Root view
```
