# Services Reference

Detailed documentation for ClaudeSpy services. Reference when modifying specific components.

## macOS Services

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

Actor managing a `tmux -C attach` control mode connection.

**Features:**
- Connects to tmux session in control mode for structured event notifications
- Parses control protocol: `%output`, `%layout-change`, `%begin/%end/%error`, `%exit`
- Unescapes octal-encoded output (`\033` → ESC character)
- Buffers output during resize to ensure clients get dimensions before new content
- Sends commands and receives responses via `%begin/%end` blocks

**Notifications:**
- `onOutput(paneId, data)` - terminal output for a pane
- `onDimensionChange(paneId, width, height)` - pane resized
- `onExit(reason)` - control mode connection closed

### TmuxControlClientManager (`ClaudeSpyServerFeature/Services/TmuxControlClientManager.swift`)

`@Observable @MainActor` managing `TmuxControlClient` instances per session.

**Methods:**
- `getClient(for:)` - returns existing or creates new client for session
- `registerPane()` / `unregisterPane()` - subscribe/unsubscribe to pane output
- `extractSessionName(from:)` - parses session from pane target

Multiple panes in the same session share one control client connection.

### PaneStream (`ClaudeSpyServerFeature/Services/PaneStream.swift`)

`@Observable @MainActor` class managing streaming to a single pane.

**States:** `disconnected` → `connecting` → `connected` | `error`

**Data Flow:**
```
TmuxControlClient ──%output──→ TmuxControlClientManager
                                        ↓
                              PaneStream.onData callback
                                        ↓
                               TerminalController.feed(data)

TmuxControlClient ──%layout-change──→ buffers output
                                        ↓
                              queries list-panes for dimensions
                                        ↓
                              sends onDimensionChange
                                        ↓
                              flushes buffered output
```

**Features:** Initial content capture, real-time dimension updates via control mode

### MirrorWindowManager (`ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift`)

`@Observable @MainActor` managing NSWindow lifecycle.

- Creates windows sized via `FontMetrics`
- Tracks windows by pane target: `[String: NSWindow]`
- Reuses existing windows (bring to front)
- Supports programmatic open/close via `HookServerService`

### TerminalController (`ClaudeSpyServerFeature/Views/TerminalContainerView.swift`)

`@Observable @MainActor` bridging SwiftTerm to SwiftUI.

- Wraps SwiftTerm's `TerminalView`
- Uses **FlippedClipView** for top alignment
- Fixed dimensions in character cells
- CoreText font metrics for cell size
- Theme support (DefaultDark/Light, SolarizedDark/Light)

### HookServerService (`ClaudeSpyServerFeature/Hooks/HookServerService.swift`)

`@Observable @MainActor` Vapor HTTP server on port 6111.

**Events:**
- `SessionStart` - auto-opens mirror window
- `SessionEnd` - auto-closes window
- `NotificationSend` - notification events
- `Stop` - stop events

### ExternalServerClient (`ClaudeSpyServerFeature/Services/ExternalServerClient.swift`)

`@Observable @MainActor` managing WebSocket to relay server.

- Connect/disconnect with pairId
- Send `WebSocketMessage` for iOS relay
- Handle incoming commands
- Track iOS connection status

### PairingManager (`ClaudeSpyServerFeature/Services/PairingManager.swift`)

`@Observable @MainActor` managing device pairing.

**States:** `unpaired` → `generatingCode` → `waitingForPairing` → `paired`

- Generates 6-char codes
- Registers with external server
- Polls for completion
- Persists to UserDefaults

## iOS Services

### RelayClient (`ClaudeSpyFeature/Services/RelayClient.swift`)

`@Observable @MainActor` managing WebSocket from iOS.

- Connects after pairing
- Receives session state and events
- Sends commands (keystroke, cancel)
- Auto-reconnects with backoff

### SessionStore (`ClaudeSpyFeature/Services/SessionStore.swift`)

`@Observable @MainActor` tracking sessions from Mac.

- Stores sessions by pane ID
- Handles hook events
- Updates on full sync
- Clears on disconnect

## Utilities

### FontMetrics (`ClaudeSpyServerFeature/Utilities/FontMetrics.swift`)

- `calculateCellSize(fontName:fontSize:)` - CoreText cell dimensions
- `swiftTermScrollerWidth` - SwiftTerm scroller width
- `horizontalBuffer` - scroller compensation (width + 4px)

See `docs/swiftterm-sizing.md` for sizing analysis.

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
- **Behavior:** restoreWindowsOnLaunch, showStatusBar, autoReconnect
- **Tmux:** tmuxPath, tmuxSocket

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

**Encrypted types:** hookEvent, sessionState, command, commandResponse, terminalSnapshot

**Unencrypted types:** registerMac/registerIOS, ping/pong, iosConnected/Disconnected, encryptedPush
