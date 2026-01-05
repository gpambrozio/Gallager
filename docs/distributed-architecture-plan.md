# ClaudeSpy Distributed Architecture Plan

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

## Phase 1: Shared Models & Infrastructure

### 1.1 Extend ClaudeSpyCommon with Networking Types

Add networking message types to the existing `ClaudeSpyCommon` module, which already contains all hook models. This keeps related types together and avoids unnecessary module proliferation.

**New file: `Sources/ClaudeSpyCommon/Models/WebSocketMessage.swift`**
```swift
/// Wrapper for all WebSocket messages between Mac, External Server, and iOS
public enum WebSocketMessage: Codable, Sendable {
    // Mac → Server
    case registerMac(RegisterMacMessage)
    case hookEvent(HookEventMessage)
    case commandResponse(CommandResponseMessage)

    // Server → Mac
    case macRegistered(MacRegisteredMessage)
    case command(CommandMessage)
    case iosConnected
    case iosDisconnected

    // iOS → Server
    case registerIOS(RegisterIOSMessage)

    // Server → iOS
    case iosRegistered(IOSRegisteredMessage)
    case macConnected
    case macDisconnected
    case sessionState(SessionStateMessage)
}
```

**New file: `Sources/ClaudeSpyCommon/Models/PairingModels.swift`**
```swift
public struct PairingRequest: Codable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let pairingCode: String
}

public struct PairingResponse: Codable, Sendable {
    public let success: Bool
    public let pairId: String?
    public let error: String?
}

public struct RegisterMacMessage: Codable, Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String
}

public struct RegisterIOSMessage: Codable, Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String
}

public struct MacRegisteredMessage: Codable, Sendable {
    public let success: Bool
}

public struct IOSRegisteredMessage: Codable, Sendable {
    public let success: Bool
    public let macDeviceName: String?
}
```

**New file: `Sources/ClaudeSpyCommon/Models/CommandModels.swift`**
```swift
public enum CommandType: String, Codable, Sendable {
    case sendKeystroke
    case cancelOperation  // Future: send Ctrl+C
    case pauseMirror
    case resumeMirror
}

public struct CommandMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let paneId: String
    public let type: CommandType
    public let payload: [String: AnyCodable]
    public let timestamp: Date
}

public struct CommandResponseMessage: Codable, Sendable {
    public let commandId: UUID
    public let success: Bool
    public let error: String?
}
```

**New file: `Sources/ClaudeSpyCommon/Models/SessionMessages.swift`**
```swift
public struct HookEventMessage: Codable, Sendable {
    public let pairId: String
    public let event: HookEvent  // Reuse existing
}

public struct SessionStateMessage: Codable, Sendable {
    public let pairId: String
    public let sessions: [String: ClaudeSession]  // Reuse existing
    public let activePanes: [String]
}
```

### 1.2 Update Package.swift

Add the external server executable target. Note that `ClaudeSpyFeature` already exists for iOS features.

**Existing module structure:**
- `ClaudeSpyCommon` - Shared models, SF Symbols, utilities (add networking types here)
- `ClaudeSpyFeature` - iOS feature module (currently placeholder, will implement iOS UI)
- `ClaudeSpyServerFeature` - macOS server feature (add WebSocket client here)
- `ClaudeSpyExternalServer` - **NEW** executable for relay server

```swift
// Add to Package.swift

// Add product
.executable(
    name: "ClaudeSpyExternalServer",
    targets: ["ClaudeSpyExternalServer"]
),

// Add target
.executableTarget(
    name: "ClaudeSpyExternalServer",
    dependencies: [
        .claudeSpyCommon,
        .vapor,
    ]
),

// Add test target
.testTarget(
    name: "ClaudeSpyExternalServerTests",
    dependencies: ["ClaudeSpyExternalServer"]
),
```

---

## Phase 2: External Server Implementation

### 2.1 Server Structure

```
Sources/ClaudeSpyExternalServer/
├── main.swift                    # Entry point, configure & run
├── configure.swift               # Vapor app configuration
├── Routes/
│   ├── routes.swift              # Route registration
│   ├── PairingController.swift   # HTTP pairing endpoints
│   └── WebSocketController.swift # WebSocket upgrade & handling
├── Services/
│   ├── PairingService.swift      # Pairing code management
│   ├── ConnectionHub.swift       # Track connected clients
│   └── RelayService.swift        # Message routing logic
└── Models/
    ├── Pair.swift                # Paired device record
    └── Connection.swift          # Active connection metadata
```

### 2.2 HTTP Endpoints

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

### 2.3 WebSocket Endpoint

```
WS /ws?pairId=xxx&deviceType=mac|ios&deviceId=xxx

Connection flow:
1. Client connects with pairId and deviceType
2. Server validates pairId exists and is valid
3. Server registers connection in ConnectionHub
4. Server notifies paired device of connection
5. Messages relayed between paired devices
```

### 2.4 Core Services

**ConnectionHub.swift**
```swift
actor ConnectionHub {
    private var connections: [String: [String: WebSocket]] = [:]
    // [pairId: [deviceType: WebSocket]]

    func register(pairId: String, deviceType: String, socket: WebSocket)
    func unregister(pairId: String, deviceType: String)
    func send(to pairId: String, deviceType: String, message: WebSocketMessage)
    func broadcast(to pairId: String, message: WebSocketMessage, excluding: String?)
}
```

**PairingService.swift**
```swift
actor PairingService {
    private var pendingCodes: [String: PendingPairing] = [:]  // code → pending
    private var activePairs: [String: Pair] = [:]             // pairId → pair

    func generateCode(deviceId: String, deviceName: String) -> (code: String, expiresAt: Date)
    func completePairing(code: String, deviceId: String, deviceName: String) -> PairingResponse
    func validatePair(pairId: String) -> Bool
    func getPair(pairId: String) -> Pair?
    func removePair(pairId: String)
}
```

**RelayService.swift**
```swift
actor RelayService {
    let hub: ConnectionHub
    let pairingService: PairingService

    func handleMacMessage(_ message: WebSocketMessage, pairId: String)
    func handleIOSMessage(_ message: WebSocketMessage, pairId: String)
    func relayHookEvent(_ event: HookEventMessage) async
    func relayCommand(_ command: CommandMessage) async
}
```

### 2.5 Docker Configuration

**Dockerfile**
```dockerfile
FROM swift:6.0-jammy as builder

WORKDIR /app
COPY ClaudeSpyPackage ./ClaudeSpyPackage

WORKDIR /app/ClaudeSpyPackage
RUN swift build -c release --target ClaudeSpyExternalServer

FROM swift:6.0-jammy-slim
WORKDIR /app
COPY --from=builder /app/ClaudeSpyPackage/.build/release/ClaudeSpyExternalServer ./

EXPOSE 8080
ENV ENVIRONMENT=production

CMD ["./ClaudeSpyExternalServer", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
```

**docker-compose.yml**
```yaml
version: '3.8'
services:
  claudespy-relay:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8080:8080"
    environment:
      - LOG_LEVEL=info
      - PAIRING_CODE_EXPIRY_SECONDS=300
    restart: unless-stopped
```

---

## Phase 3: Mac App Updates

### 3.1 New Components

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

## Phase 4: iOS App Implementation

### 4.1 App Structure

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

### Week 1: Foundation
- [ ] Add networking message types to `ClaudeSpyCommon` module
- [ ] Update Package.swift with `ClaudeSpyExternalServer` executable target
- [ ] Create `ClaudeSpyExternalServer` target skeleton
- [ ] Implement basic Vapor app with health endpoint

### Week 2: External Server Core
- [ ] Implement PairingService
- [ ] Implement ConnectionHub
- [ ] Implement WebSocket endpoint
- [ ] Implement RelayService
- [ ] Add HTTP pairing endpoints
- [ ] Write unit tests for services

### Week 3: Mac App Integration
- [ ] Implement ExternalServerClient
- [ ] Implement PairingManager
- [ ] Add RemoteAccessSettingsView
- [ ] Integrate with HookServerService to forward events
- [ ] Implement TmuxCommandExecutor
- [ ] Test Mac ↔ Server communication

### Week 4: iOS App
- [ ] Implement RelayClient in `ClaudeSpyFeature`
- [ ] Implement SessionStore in `ClaudeSpyFeature`
- [ ] Replace placeholder ContentView with real implementation
- [ ] Create PairingView
- [ ] Create SessionListView and SessionDetailView
- [ ] Update `ClaudeSpy` iOS target to use ClaudeSpyFeature
- [ ] Test full end-to-end flow

### Week 5: Docker & Deployment
- [ ] Create Dockerfile
- [ ] Create docker-compose.yml
- [ ] Test containerized deployment
- [ ] Document deployment process
- [ ] Create production configuration

### Week 6: Polish & Testing
- [ ] End-to-end integration tests
- [ ] Error handling improvements
- [ ] Reconnection logic
- [ ] UI polish
- [ ] Documentation updates

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

1. **Server hosting**: Where will the external server be deployed? (AWS, GCP, DigitalOcean, self-hosted?)
2. **Domain/SSL**: What domain will be used? Need SSL certificate for WSS.
3. **Tmux keystroke format**: What format should keystroke commands use? (raw keys, escape sequences, tmux key names?)
4. **Session history limit**: How many events should iOS display? Currently Mac keeps 5.
5. **Reconnection behavior**: Should iOS auto-reconnect on network recovery?

---

*This plan was generated with a heavy sigh. The universe tends toward entropy, and software tends toward complexity. At least this complexity serves a purpose—unlike most things.*
