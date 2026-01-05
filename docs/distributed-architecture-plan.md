# ClaudeSpy Distributed Architecture Plan

## Current Status (Updated: January 2026)

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: Shared Models | ✅ **COMPLETE** | Implemented as `ClaudeSpyNetworking` module (not ClaudeSpyCommon) |
| Phase 2: External Server | ✅ **COMPLETE** | Full Vapor relay server with pairing, WebSocket, Docker |
| Docker & Deployment | ✅ **COMPLETE** | Deployed to Hetzner with Caddy reverse proxy |
| Phase 3: Mac App Updates | ✅ **COMPLETE** | ExternalServerClient, PairingManager, TmuxCommandExecutor, UI |
| Phase 4: iOS App | ❌ Not Started | ClaudeSpyFeature is a stub ("Hello, World!") |

---

## Overview

Transform ClaudeSpy from a standalone Mac app into a distributed system with three components:
1. **Mac App** - Receives Claude Code hooks, forwards to external server, receives commands
2. **External Server** - Vapor-based relay server, handles device pairing, runs in Docker
3. **iOS App** - Monitors sessions remotely, sends commands back to Mac

## Architecture Diagram

```
┌──────────────────┐         ┌──────────────────────┐         ┌──────────────────┐
│   Claude Code    │         │                      │         │                  │
│    (tmux)        │         │   External Server    │         │    iOS App       │
│                  │         │      (Vapor)         │         │                  │
└────────┬─────────┘         │   ┌──────────────┐   │         └────────┬─────────┘
         │                   │   │   Pairing    │   │                  │
   HTTP POST                 │   │   Storage    │   │                  │
   (hooks)                   │   └──────────────┘   │                  │
         │                   │   ┌──────────────┐   │                  │
         ▼                   │   │  WebSocket   │   │                  │
┌──────────────────┐         │   │    Hub       │   │         ┌────────┴─────────┐
│     Mac App      │◄──WS───►│   └──────────────┘   │◄───WS──►│  WebSocket       │
│  (ClaudeSpy)     │         │   ┌──────────────┐   │         │  Client          │
│                  │         │   │   Session    │   │         │                  │
│ ┌──────────────┐ │         │   │   State      │   │         │ ┌──────────────┐ │
│ │ Hook Server  │ │         │   └──────────────┘   │         │ │ Pairing UI   │ │
│ │ (port 6111)  │ │         │                      │         │ └──────────────┘ │
│ └──────────────┘ │         │   Docker Container   │         │ ┌──────────────┐ │
│ ┌──────────────┐ │         │   (port 443/8080)    │         │ │ Session View │ │
│ │ WS Client    │ │         │                      │         │ └──────────────┘ │
│ └──────────────┘ │         └──────────────────────┘         │ ┌──────────────┐ │
│ ┌──────────────┐ │                                          │ │ Command UI   │ │
│ │ Tmux Control │ │                                          │ └──────────────┘ │
│ └──────────────┘ │                                          └──────────────────┘
└──────────────────┘
```

## Data Flow

### Event Flow (Mac → iOS)
```
1. Claude Code sends hook event to Mac app (HTTP POST localhost:6111)
2. Mac app processes event locally (updates UI, session state)
3. Mac app forwards event to external server via WebSocket
4. External server relays to connected iOS client via WebSocket
5. iOS app displays event in session monitor
```

### Command Flow (iOS → Mac)
```
1. User initiates command in iOS app (e.g., send keystroke)
2. iOS sends command via WebSocket to external server
3. External server relays command to Mac via WebSocket
4. Mac app receives command, validates it
5. Mac app sends keystroke to appropriate tmux pane
```

### Pairing Flow
```
1. User opens Mac app, goes to "Remote Access" settings
2. Mac app generates 6-character pairing code
3. Mac app registers code with external server (includes device ID, name)
4. User opens iOS app, enters pairing code
5. External server validates code, creates "pair" record
6. Both apps receive confirmation, WebSocket connection established
7. Pairing code expires after 5 minutes or successful pairing
```

---

## Phase 1: Shared Models & Infrastructure ✅ COMPLETE

> **Implementation Note:** Networking models were implemented in a dedicated `ClaudeSpyNetworking` module rather than extending `ClaudeSpyCommon`. This provides better separation of concerns and allows the networking models to be used by the Linux-based external server without pulling in macOS/iOS-specific dependencies.

### 1.1 ClaudeSpyNetworking Module

**Actual location:** `Sources/ClaudeSpyNetworking/Models/`

The networking module contains all shared message types for Mac ↔ Server ↔ iOS communication:

```
Sources/ClaudeSpyNetworking/
├── Models/
│   ├── WebSocketMessage.swift   # 16+ message types with JSON serialization
│   ├── PairingModels.swift      # Pairing flow models
│   ├── CommandModels.swift      # Remote command protocol
│   ├── HookModels.swift         # Claude Code hook event types (~530 lines)
│   └── RelayMessages.swift      # Session state synchronization
└── (exports all types publicly)
```

**Key implemented types:**

- `WebSocketMessage` - Comprehensive enum with custom JSON encoding (type + payload pattern)
- `PairingRegistration`, `PairingCompletion`, `PairingResponse` - HTTP pairing flow
- `RegisterMacMessage`, `RegisterIOSMessage` - WebSocket registration after pairing
- `CommandMessage`, `CommandResponseMessage` - Remote command protocol
- `HookEvent`, `ClaudeSession`, `HookAction` - Full Claude Code integration
- `SessionStateMessage`, `HookEventMessage` - State sync messages
- `AnyCodable` - Type-erased wrapper for arbitrary JSON payloads

All types implement `Sendable` for Swift 6 strict concurrency.

### 1.2 Package.swift Updates

**Current module structure:**
- `ClaudeSpyCommon` - Shared UI utilities (SF Symbols, extensions)
- `ClaudeSpyNetworking` - **Platform-agnostic networking models** (NEW)
- `ClaudeSpyFeature` - iOS feature module (placeholder)
- `ClaudeSpyServerFeature` - macOS server feature
- `ClaudeSpyExternalServer` - Linux-ready relay server executable

The external server depends on `ClaudeSpyNetworking` (not `ClaudeSpyCommon`) to avoid pulling macOS/iOS dependencies into the Linux build.

---

## Phase 2: External Server Implementation ✅ COMPLETE

### 2.1 Server Structure (Implemented)

```
Sources/ClaudeSpyExternalServer/
├── main.swift                    # Vapor async/await entry point
├── configure.swift               # Server config, service initialization
├── Routes/
│   ├── routes.swift              # Route registration
│   ├── PairingController.swift   # HTTP pairing endpoints
│   └── WebSocketController.swift # WebSocket upgrade & message handling
├── Services/
│   ├── PairingService.swift      # Actor: code management, pair storage
│   ├── ConnectionHub.swift       # Actor: WebSocket connection tracking
│   └── RelayService.swift        # Actor: message routing orchestration
├── Models/
│   ├── Pair.swift                # Paired device record (IDs, names, timestamp)
│   ├── Connection.swift          # WebSocket + metadata wrapper
│   └── PendingPairing.swift      # Temporary pairing code holder
└── Extensions/
    └── StorageKeys.swift         # Vapor storage type keys
```

### 2.2 HTTP Endpoints (Implemented)

```
POST /api/pairing/register
  Body: { deviceId, deviceName, pairingCode }
  Response: { success, pairId?, error? }
  Description: Mac registers pairing code, receives pairId

POST /api/pairing/complete
  Body: { pairingCode, deviceId, deviceName }
  Response: { success, pairId?, macDeviceName?, error? }
  Description: iOS completes pairing, receives pairId and Mac info

GET /api/pairing/:pairId/status
  Response: { valid, macConnected, iosConnected }
  Description: Check pairing status

DELETE /api/pairing/:pairId
  Description: Unpair devices

GET /health
  Response: { status: "ok" }
```

### 2.3 WebSocket Endpoint (Implemented)

```
WS /api/ws?pairId=xxx&deviceType=mac|ios&deviceId=xxx

Connection flow:
1. Client connects with pairId and deviceType
2. Server validates pairId exists and is valid
3. Server registers connection in ConnectionHub
4. Server notifies paired device of connection
5. Messages relayed between paired devices
6. On disconnect: cleanup and notify paired device
```

### 2.4 Core Services (Implemented)

All services are implemented as Swift actors for thread-safe concurrent access:

**PairingService** - Manages device pairing lifecycle
- Pending codes with 5-minute expiry and auto-cleanup
- Active pairs stored by UUID
- Device name lookups for notifications

**ConnectionHub** - WebSocket connection manager
- Tracks `[pairId: [deviceType: Connection]]` hierarchy
- Status checks: `isMacConnected()`, `isIOSConnected()`
- Message sending with exclude filter for broadcasts

**RelayService** - Message routing orchestration
- Routes Mac messages to iOS (hook events, session state, command responses)
- Routes iOS messages to Mac (commands, state requests)
- Connection state notifications (macConnected, iosDisconnected, etc.)
- Smart state sync: iOS gets session state on connect if Mac ready

### 2.5 Docker Configuration (Implemented)

**Dockerfile** - Multi-stage build for minimal image size:
- Swift 6.0 builder stage with release optimization
- Slim runtime image with non-root user
- Health check support
- Environment variable configuration

**docker-compose.yml** - Production orchestration:
- Health check via curl to `/health`
- Environment: `LOG_LEVEL`, `PAIRING_CODE_EXPIRY_SECONDS`
- Restart policy: `unless-stopped`

### 2.6 Deployment (Implemented)

The external server is deployed to **Hetzner** with:
- Caddy reverse proxy for TLS termination (HTTPS/WSS)
- Docker container running the Vapor server
- Domain configured for secure WebSocket connections

---

## Phase 3: Mac App Updates ✅ COMPLETE

> **Implementation:** All components have been implemented in `ClaudeSpyServerFeature`.

### 3.1 New Components (Implemented)

**ExternalServerClient.swift**
```swift
@Observable
@MainActor
final class ExternalServerClient {
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    private(set) var state: ConnectionState = .disconnected
    private(set) var isIOSConnected: Bool = false

    private var webSocket: URLSessionWebSocketTask?
    private var pairId: String?

    func connect(serverURL: URL, pairId: String) async throws
    func disconnect()
    func send(_ message: WebSocketMessage) async throws
    func handleIncoming(_ message: WebSocketMessage)
}
```

**PairingManager.swift**
```swift
@Observable
@MainActor
final class PairingManager {
    enum State {
        case unpaired
        case generatingCode
        case waitingForPairing(code: String, expiresAt: Date)
        case paired(pairId: String, iosDeviceName: String)
        case error(String)
    }

    private(set) var state: State = .unpaired
    private let serverURL: URL

    func generatePairingCode() async throws -> String
    func cancelPairing()
    func unpair()
}
```

**TmuxCommandExecutor.swift**
```swift
actor TmuxCommandExecutor {
    let tmuxService: TmuxService

    func execute(_ command: CommandMessage) async throws -> CommandResponseMessage
    func sendKeystroke(paneId: String, keys: String) async throws
}
```

### 3.2 Settings Updates

Add to AppSettings:
```swift
// Remote Access
var externalServerURL: String = "wss://your-server.com"
var pairId: String? = nil
var pairedIOSDeviceName: String? = nil
var autoConnectToServer: Bool = true
```

### 3.3 UI Updates

**New: RemoteAccessSettingsView.swift**
- Display pairing status
- Generate pairing code button
- Show QR code for pairing (optional)
- Connected iOS device info
- Unpair button

**Update: HookServerService**
- After processing hook events, forward to ExternalServerClient if connected

---

## Phase 4: iOS App Implementation ❌ NOT STARTED

> **Current State:** `ClaudeSpyFeature` contains only a stub `ContentView.swift` that displays "Hello, World!". The entire iOS implementation remains to be done.

### 4.1 App Structure (TODO)

Use the existing `ClaudeSpyFeature` module (currently a placeholder) for iOS-specific code:

```
Sources/ClaudeSpyFeature/
├── Services/
│   ├── RelayClient.swift         # WebSocket client to external server
│   └── SessionStore.swift        # Local session state management
├── Views/
│   ├── ContentView.swift         # Main view (replace placeholder)
│   ├── MainView.swift            # Tab-based navigation
│   ├── Pairing/
│   │   ├── PairingView.swift     # Enter pairing code
│   │   └── PairedStatusView.swift
│   ├── Sessions/
│   │   ├── SessionListView.swift # List active sessions
│   │   ├── SessionDetailView.swift
│   │   └── EventRow.swift
│   └── Commands/
│       └── CommandPaletteView.swift
└── Models/
    └── IOSSettings.swift         # Persisted settings
```

The iOS app entry point lives in `ClaudeSpy/` target (currently unused), which will import `ClaudeSpyFeature`.

### 4.2 Core Views

**PairingView.swift**
- 6-character code input field
- "Pair" button
- Visual feedback on success/failure
- Navigate to main view on success

**SessionListView.swift**
- List of active Claude sessions from Mac
- Each row shows: pane info, latest event, status indicator
- Tap to view session detail

**SessionDetailView.swift**
- Full event history for selected session
- Command buttons (send keystroke, etc.)
- Connection status indicator

### 4.3 Services

**RelayClient.swift**
```swift
@Observable
@MainActor
final class RelayClient {
    enum State {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case error(String)
    }

    private(set) var state: State = .disconnected
    private(set) var isMacConnected: Bool = false

    func connect(serverURL: URL, pairId: String) async
    func disconnect()
    func sendCommand(_ command: CommandMessage) async throws
}
```

**SessionStore.swift**
```swift
@Observable
@MainActor
final class SessionStore {
    private(set) var sessions: [String: ClaudeSession] = [:]
    private(set) var activePanes: [String] = []

    func handleEvent(_ event: HookEventMessage)
    func handleStateUpdate(_ state: SessionStateMessage)
    func clearOnDisconnect()
}
```

---

## Phase 5: Future Enhancements (Phase 2 Roadmap)

### 5.1 Push Notifications
- APNs setup for iOS app
- External server sends push when important events occur
- Events that trigger push: session start, permission request, errors
- iOS app wakes on push, connects to receive full state

### 5.2 Multi-Mac Support
- iOS app can store multiple pairings
- Switch between paired Macs
- UI for managing multiple connections

### 5.3 Security Hardening
- TLS certificate pinning
- Pair token rotation
- Rate limiting on pairing attempts
- Audit logging

### 5.4 Persistence
- External server: Redis/PostgreSQL for durable pair storage
- Session history retention
- Offline event queuing

---

## Implementation Order

### Week 1: Foundation ✅ COMPLETE
- [x] Add networking message types (created `ClaudeSpyNetworking` module)
- [x] Update Package.swift with `ClaudeSpyExternalServer` executable target
- [x] Create `ClaudeSpyExternalServer` target skeleton
- [x] Implement basic Vapor app with health endpoint

### Week 2: External Server Core ✅ COMPLETE
- [x] Implement PairingService (actor with code expiry)
- [x] Implement ConnectionHub (actor with WebSocket tracking)
- [x] Implement WebSocket endpoint (`/api/ws`)
- [x] Implement RelayService (message routing)
- [x] Add HTTP pairing endpoints
- [x] Write unit tests for services (`PairingServiceTests.swift`)

### Week 3: Mac App Integration ✅ COMPLETE
- [x] Implement ExternalServerClient (WebSocket client with reconnection)
- [x] Implement PairingManager (code generation, registration, polling)
- [x] Add RemoteAccessSettingsView (pairing UI, connection status)
- [x] Integrate with HookServerService to forward events
- [x] Implement TmuxCommandExecutor (keystroke, cancel commands)
- [x] Test Mac ↔ Server communication (builds and passes tests)

### Week 4: iOS App ❌ NOT STARTED
- [ ] Implement RelayClient in `ClaudeSpyFeature`
- [ ] Implement SessionStore in `ClaudeSpyFeature`
- [ ] Replace placeholder ContentView with real implementation
- [ ] Create PairingView
- [ ] Create SessionListView and SessionDetailView
- [ ] Update `ClaudeSpy` iOS target to use ClaudeSpyFeature
- [ ] Test full end-to-end flow

### Week 5: Docker & Deployment ✅ COMPLETE
- [x] Create Dockerfile (multi-stage, non-root user)
- [x] Create docker-compose.yml (health checks, env config)
- [x] Test containerized deployment
- [x] Document deployment process
- [x] Create production configuration (Hetzner + Caddy)

### Week 6: Polish & Testing ⏳ PARTIAL
- [ ] End-to-end integration tests
- [ ] Error handling improvements
- [ ] Reconnection logic
- [ ] UI polish
- [x] Documentation updates (this file)

---

## Technical Decisions

### Why WebSocket over HTTP long-polling?
- True bidirectional communication needed for commands
- Lower latency for real-time event streaming
- Single persistent connection instead of repeated HTTP requests
- Native support in URLSession and Vapor

### Why device pairing over user accounts?
- Simpler architecture, no user database needed
- Privacy-focused (no centralized user data)
- Works offline between pairing events
- Natural fit for single-user developer tool

### Why in-memory state over database?
- MVP doesn't need persistence
- Pairs can be re-established if server restarts
- Lower complexity for initial implementation
- Can add Redis/PostgreSQL later if needed

### Why separate executable over embedded server?
- Clear separation of concerns
- Independent deployment and scaling
- Can run on different infrastructure than development Mac
- Docker-friendly deployment model

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Network reliability | Exponential backoff reconnection, offline buffering |
| Security vulnerabilities | TLS, code expiry, rate limiting, input validation |
| Server scalability | Stateless design, horizontal scaling ready |
| iOS app rejection | Follow HIG, no private APIs, clear purpose |
| Complex debugging | Structured logging, message tracing, health endpoints |

---

## Open Questions

1. ~~**Server hosting**: Where will the external server be deployed?~~ ✅ **RESOLVED**: Hetzner VPS with Docker
2. ~~**Domain/SSL**: What domain will be used?~~ ✅ **RESOLVED**: Caddy handles TLS termination with automatic certificates
3. **Tmux keystroke format**: What format should keystroke commands use? (raw keys, escape sequences, tmux key names?)
4. **Session history limit**: How many events should iOS display? Currently Mac keeps 5.
5. **Reconnection behavior**: Should iOS auto-reconnect on network recovery?

### New Questions (from implementation)

6. **Mac WebSocket client**: Should use URLSession's WebSocketTask or a third-party library?
7. **iOS state persistence**: Should pairing info persist across app launches? (Currently server is in-memory only)
8. **Error recovery UI**: How should the Mac/iOS apps surface connection errors to users?

---

*This plan was generated with a heavy sigh. The universe tends toward entropy, and software tends toward complexity. At least this complexity serves a purpose—unlike most things. Update: At least some progress has been made. The server works. The iOS app... exists, in the most charitable interpretation of that word.*
