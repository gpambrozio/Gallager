# Services Reference

Detailed documentation for ClaudeSpy services. Reference when modifying specific components.

## macOS Services

### AppCoordinator (`ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`)

`@Observable @MainActor` central coordinator for all services.

**Responsibilities:**
- Creates and owns all services
- Wires callbacks between services (hook events, pane changes, commands)
- Two-phase init: sync (core services) + async (`setupAllServices()` for E2EE, connections)
- Auto-connects to paired devices on startup
- Observes system wake for reconnection

### TmuxService (`ClaudeSpyServerFeature/Services/TmuxService.swift`)

`@Observable @MainActor` class abstracting tmux CLI interactions.

**Methods:**
- `refreshPanes()` - discovers all panes across sessions
- `validatePane()` - checks if pane target exists
- `capturePane()` - captures scrollback with ANSI sequences
- `capturePaneWithScrollbackForStreaming()` - captures with cursor positioning for streaming init
- `getPaneDimensions()` / `getPaneId()` - dimension tracking
- `sendKeys()` / `sendInterrupt()` - send input to panes
- `createSession()` - creates new tmux session with dimensions

**Config:** `tmuxPath` (default: `/opt/homebrew/bin/tmux`), optional `socketPath`

### TmuxControlClient (`ClaudeSpyServerFeature/Services/TmuxControlClient.swift`)

Actor managing a `tmux -C attach -f no-output,ignore-size` control mode connection for commands and event notifications. Live terminal data is delivered separately via `PipePaneReader`.

**Features:**
- Connects to tmux session in control mode with `-f no-output,ignore-size` (suppresses `%output` events)
- Sends commands and receives responses via `%begin/%end` blocks (FIFO command queue)
- Parses event notifications: `%layout-change`, `%session-changed`, `%exit`
- Tracks per-pane cached dimensions for change detection
- Uses AsyncStream + single consumer for strict ordering of control mode messages

**Callbacks:**
- `onDimensionChange(paneId, width, height)` - pane resized (from `%layout-change`)
- `onPaneExited(paneId)` - pane closed
- `onSessionChanged(sessionId, name)` - session switched
- `onExit(reason)` - control mode connection closed

### TmuxControlClientManager (`ClaudeSpyServerFeature/Services/TmuxControlClientManager.swift`)

`@Observable @MainActor` managing `TmuxControlClient` instances per session.

**Methods:**
- `getClient(for:)` - returns existing or creates new client for session
- `registerPaneDimensions()` / `unregisterPane()` - register/unregister pane for dimension tracking
- `sendCommand(_:sessionName:)` - send tmux command through the control client
- `setOnDimensionChange()` - forward dimension changes to PaneStreamManager
- `setOnPanesChanged()` - callback when panes exit (for cleanup)
- `extractSessionName(from:)` - parses session from pane target

Multiple panes in the same session share one control client connection. The control client operates in `no-output` mode — it only handles commands and event notifications.

### PipePaneReader (`ClaudeSpyServerFeature/Services/PipePaneReader.swift`)

`actor` managing FIFO-based raw byte delivery from tmux `pipe-pane` for a single pane. One reader instance lives for the pane's full lifetime — mirror toggling never restarts it.

**Features:**
- Creates per-pane FIFO (`/tmp/claudespy-pipe-<id>.fifo`)
- Starts `pipe-pane -O "cat > fifo"` via control mode command
- Reads raw PTY bytes, filtering tmux `ESC k ... ESC \` title sequences and parsing OSC 9/777/9;4/0/2/52 events
- AsyncStream + single consumer task for strict FIFO ordering
- Forwards events through a single `PipePaneReaderDelegate` (`@MainActor` protocol, one method per event type)

**Three data-delivery modes:**
- **`scanOnly`** (default after `startPipePane`): parser doesn't build `filteredData`, data bytes are discarded. OSC events still flow.
- **`buffering`** (`setBuffering(true)`): bytes queued instead of forwarded. Used while a `capture-pane` snapshot is being taken.
- **`live`** (`flushBuffer`): drains the queue to the delegate in order, then forwards subsequent bytes directly.

**Lifecycle:**
- `setDelegate(_:)` - attach the delegate that receives data + OSC events
- `startPipePane(controlClientManager:sessionName:)` - create FIFO, send pipe-pane command, open for reading. Reader starts in scan-only mode
- `setBuffering(_:)` - flip into buffering mode (bytes queued) or back to scan-only mode (queue dropped, bytes discarded)
- `flushBuffer()` - drain the queue through the delegate and switch to live mode
- `stopPipePane()` - clean up FIFO, close file handle (called when the pane disappears)

### PaneStreamManager (`ClaudeSpyServerFeature/Services/PaneStreamManager.swift`)

`@Observable @MainActor` owning one `PipePaneReader` per known pane and multiplexing its events to subscribers. Conforms to `PipePaneReaderDelegate`, so all event wiring lives in one place.

**Per-pane lifecycle:**
- New pane discovered → `startReader` creates a `PipePaneReader`, attaches the manager as delegate, calls `startPipePane()` (scan-only mode)
- Pane disappears → `tearDownReader` calls `stopPipePane`, unregisters dimensions, drops the entry

**Data Flow:**
```
tmux PTY ──pipe-pane──→ FIFO ──→ PipePaneReader ──→ PipePaneReaderDelegate
                                                            ↓
                                                   subscriber callbacks

TmuxControlClient ──%layout-change──→ updateDimensions → subscriber onDimensionChange
```

**Subscribe flow (first subscriber on a pane):**
1. `setBuffering(true)` — start retaining live bytes
2. Refresh dimensions via `tmuxService.getPaneDimensions`, register pane for control-mode dimension tracking
3. `capture-pane` snapshot via control mode
4. Add subscriber to the reader's context
5. `flushBuffer()` — buffered bytes flow through `didReceiveData` → `forwardData` → subscriber's `onData`. Subsequent bytes flow live.

**Unsubscribe flow (last subscriber leaves):**
- `setBuffering(false)` returns the reader to scan-only mode. The reader stays attached to the FIFO so OSC events keep flowing for desktop notifications + sidebar UI.

**Methods:**
- `startMonitoring(panes:)` - create readers for all initial panes (called once on startup)
- `updateMonitoring(panes:)` - tear down readers for dead panes, start readers for new panes (called on periodic refresh and on `%session-changed`)
- `subscribe(paneId:target:onData:onDimensionChange:onTitleChange:onNotification:onClipboard:)` - subscribe with callbacks
- `unsubscribe(_:)` - remove subscription (returns reader to scan-only if last)
- `currentContent(for:)` - capture current terminal content without subscribing (for multi-device initial state)
- `updateDimensions(paneId:width:height:)` - propagate dimension changes
- `reportTitleChange(paneId:title:fromSubscription:)` - forward a title detected by a subscriber's SwiftTerm to other subscribers
- `mouseModeSequences(for:)` - DEC private mode escape sequences for the pane's current mouse tracking mode
- `disconnectAll()` - shutdown cleanup

**Internal state:** A single `readers: [String: ReaderContext]` dictionary keyed by paneId. Each context holds the reader, target, sessionName, dimensions, subscriber UUIDs, and the latest known title.

### MirrorWindowManager (`ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift`)

`@Observable @MainActor` managing NSWindow lifecycle.

- Tracks sessions and windows by pane target
- Handles hook events (SessionStart opens window, SessionEnd closes)
- Respects user-closed state (won't reopen until session ends)
- Periodic session validation cleans up stale sessions
- `updatePaneStates(from:)` syncs pane state from tmux, removing stale entries

### TerminalContainerView (`ClaudeSpyServerFeature/Views/TerminalContainerView.swift`)

`@Observable @MainActor` bridging SwiftTerm to SwiftUI.

- Wraps SwiftTerm's `TerminalView`
- Uses **FlippedClipView** for top alignment
- Fixed dimensions in character cells
- CoreText font metrics for cell size
- Theme support (DefaultDark/Light, SolarizedDark/Light)

### HookServerService (`ClaudeSpyServerFeature/Hooks/HookServerService.swift`)

`actor` HTTP server on a dynamically allocated port (written to `~/.claudespy-port`).

**Endpoints:**
- `GET /health` - Health check
- `POST /api/hooks` - Hook event receiver

**Events:**
- `SessionStart` - auto-opens mirror window
- `SessionEnd` - auto-closes window
- `NotificationSend` - notification events
- `Stop` - stop events

### DeviceConnectionManager (`ClaudeSpyServerFeature/Services/DeviceConnectionManager.swift`)

`@Observable @MainActor` managing connections to all paired iOS devices.

**Features:**
- Wraps multiple `DeviceConnection` instances (one per paired device)
- Broadcasts events to all connected devices
- Combined state for UI display (`combinedState`)
- Auto-reconnect on system wake

**Broadcasting Methods:**
- `sendHookEventToAll()` - forward hook events
- `sendTerminalStreamToAll()` - forward terminal data
- `pushSessionStateToAll()` - sync session state

**Callbacks (set by AppCoordinator):**
- `onCommand` - handle commands from any iOS device
- `onSessionStateRequest` - provide current session state
- `onPartnerKeyReceived` - persist E2EE partner keys

### DeviceConnection (`ClaudeSpyServerFeature/Services/DeviceConnection.swift`)

`@Observable @MainActor` WebSocket connection to a single paired iOS device.

**States:** `disconnected` → `connecting` → `connected` | `reconnecting(attempt)` | `error`

- Manages WebSocket lifecycle with relay server
- E2EE encryption per device
- Auto-reconnects with exponential backoff
- Sends/receives all message types (hook events, commands, terminal stream, session state)

### PairingManager (`ClaudeSpyServerFeature/Services/PairingManager.swift`)

`@Observable @MainActor` managing device pairing.

**States:** `idle` → `generatingCode` → `waitingForPairing(code, expiresAt)` | `error`

- Generates 6-char alphanumeric codes (excludes I and O)
- Registers with external server (includes E2EE public key)
- Polls for pairing completion
- Supports multiple paired devices
- `onDevicePaired` callback triggers connection to newly paired device
- Partner public keys received via WebSocket after pairing

### TerminalStreamService (`ClaudeSpyServerFeature/Services/TerminalStreamService.swift`)

`@Observable @MainActor` streaming terminal data to iOS devices.

**Batching:** 50ms minimum interval, 8KB max batch size (20 updates/sec max)

**Multi-Device Support:**
- Reference-counted streams (`deviceSubscriberCount` per pane)
- `startStreaming()` reuses existing stream if one exists (increments count, sends current content)
- `stopStreaming()` decrements count; only fully stops when count reaches 0
- `stopStreaming(force: true)` bypasses count for system-level cleanup
- `stopAllStreams()` / `stopStreamsForClosedPanes()` always use `force: true`

**Message Types:** `initialState`, `dataChunk`, `dimensionChange`, `streamEnd`

### TmuxCommandExecutor (`ClaudeSpyServerFeature/Services/TmuxCommandExecutor.swift`)

Actor executing commands from iOS devices.

- Receives `CommandMessage` from `DeviceConnectionManager`
- Dispatches to `TmuxService` (sendKeys, sendInterrupt, etc.)
- Returns `CommandResponseMessage` (success/failure)

### PluginService (`ClaudeSpyServerFeature/Services/PluginService.swift`)

`@Observable @MainActor` managing Claude Code plugin detection and installation.

**States:** `unknown` → `checking` → `installed(version)` | `notInstalled` → `installing` → `installed` | `installationFailed`

- Detects plugin at `~/.claude/plugins/`
- Installs bundled plugin from app resources
- First-launch setup flow via `PluginSetupView`

### ClaudeProjectScanner (`ClaudeSpyServerFeature/Services/ClaudeProjectScanner.swift`)

Actor scanning for Claude Code projects.

- Reads `~/.claude.json` for project paths
- Validates projects have `.claude` subdirectory
- Sorts by most recently used (session timestamps)
- Results sent to iOS for project list display

### ClaudePathDetector (`ClaudeSpyServerFeature/Services/ClaudePathDetector.swift`)

Static utility detecting the `claude` CLI path.

- Checks common locations (`/usr/local/bin/claude`, homebrew paths, etc.)
- Used by `TerminalLauncher` for auto-running Claude in new sessions

### TerminalLauncher (`ClaudeSpyServerFeature/Services/TerminalLauncher.swift`)

`@MainActor` utility for launching tmux sessions in external terminals.

- Supports Terminal.app, iTerm2, Warp, Kitty, Alacritty, custom
- Attaches to existing tmux sessions
- Used from iOS "open in terminal" commands

### DockIconManager (`ClaudeSpyServerFeature/Managers/DockIconManager.swift`)

`@MainActor` managing dock icon visibility.

- App runs as accessory (no dock icon) when no windows visible
- Switches to regular mode when windows open
- Ignores menu bar and popover windows

### SleepPreventionManager (`ClaudeSpyServerFeature/Managers/SleepPreventionManager.swift`)

`@MainActor` preventing Mac sleep during active sessions.

- Uses IOKit `IOPMAssertionCreateWithName` assertions
- Enabled/disabled via settings toggle
- Automatically releases when all sessions end

### LoginItemService (`ClaudeSpyServerFeature/Services/LoginItemService.swift`)

Static utility for launch-at-login management.

- Uses `SMAppService.mainApp` for registration
- Appears in System Settings > General > Login Items

### UpdaterController (`ClaudeSpyServerFeature/Services/UpdaterController.swift`)

`@Observable @MainActor` wrapping Sparkle updater for SwiftUI.

- Exposes `canCheckForUpdates` binding
- `checkForUpdates()` action

## iOS Services

### RelayClient (`ClaudeSpyFeature/Services/RelayClient.swift`)

`@Observable @MainActor` managing WebSocket from iOS to relay server.

- Connects via `MacConnection` wrapper per paired Mac
- Receives session state, hook events, terminal stream data
- Sends commands (keystroke, cancel, start/stop stream)
- Auto-reconnects with exponential backoff

### SessionStore (`ClaudeSpyFeature/Services/SessionStore.swift`)

`@Observable @MainActor` tracking sessions from Mac.

- Stores sessions by pane ID
- Handles hook events
- Updates on full sync
- Clears on disconnect

## Utilities

### ProcessRunner (`ClaudeSpyServerFeature/Utilities/ProcessRunner.swift`)

Actor for external processes.

- Async execution, stdout/stderr collection
- Thread-safe `OutputCollector` with NSLock
- Returns `ProcessResult` (exit code, stdout, stderr)

## Models

### PaneInfo (`ClaudeSpyServerFeature/Models/PaneInfo.swift`)

```swift
id, target, sessionName, windowIndex, paneIndex
command, currentPath, width, height, isActive
```

### AppSettings (`ClaudeSpyServerFeature/Models/Settings.swift`)

`@Observable @MainActor` with UserDefaults:

- **Terminal:** fontName, fontSize, scrollbackLines, theme
- **Behavior:** openPanesWindowOnLaunch, showStatusBar, autoConnectToServer, preventSleepDuringSessions
- **Tmux:** tmuxPath, tmuxSocket
- **Remote Access:** externalServerURL, deviceId, pairedDevices
- **Claude:** autoRunClaudeInProjects, claudeCommandPath
- **Plugin:** hasCompletedPluginSetup

### PairedDevice (`ClaudeSpyServerFeature/Models/Settings.swift`)

```swift
id, deviceName, partnerPublicKey, partnerPublicKeyId, pairedAt, customName
```

Represents a paired iOS device with E2EE key info.

## Push Notifications

**Configuration** (`.env`):
```bash
APNS_KEY_PATH=/secrets/AuthKey.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_BUNDLE_ID=com.example.app
APNS_ENVIRONMENT=development  # or "production"
```

**Key files:**
- `ClaudeSpyExternalServer/Services/APNsService.swift`
- `ClaudeSpyExternalServer/Services/PushTokenStore.swift`
- `ClaudeSpyFeature/Services/PushNotificationService.swift`

**Events:** sessionStart, sessionEnd, permissionRequest, stop, notification

**Important:** APNs environment must match build type (Xcode=development, App Store=production)

## E2EE Encryption

See `docs/e2ee-encryption-plan.md` for full design.

**Primitives:**
- Key Exchange: X25519 ECDH
- Symmetric: ChaChaPoly (ChaCha20-Poly1305 AEAD)
- Storage: Keychain with shared access group

**Key files:**
- `ClaudeSpyEncryption/E2EEService.swift`
- `ClaudeSpyEncryption/KeyManager.swift`
- `ClaudeSpyNotificationExtension/NotificationService.swift`

**Encrypted types:** hookEvent, sessionState, command, commandResponse, terminalStream

**Unencrypted types:** registerMac/registerIOS, ping/pong, iosConnected/Disconnected, encryptedPush
