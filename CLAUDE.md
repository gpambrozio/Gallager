# Project Overview

**ClaudeSpy** is a **distributed system** for monitoring Claude Code sessions across devices. It consists of three components:
1. **Mac App** - Displays real-time mirrors of tmux panes, receives Claude Code hooks, forwards events to external server
2. **External Server** - Vapor-based relay server handling device pairing and WebSocket communication (runs in Docker)
3. **iOS App** - Remote session monitoring with command capabilities

Built with **Swift 6.1+** and **SwiftUI**, targeting **macOS 15.0+** and **iOS 17.0+**. All concurrency is handled with **Swift Concurrency** (async/await, actors, @MainActor isolation).

## What This System Does

The Mac app displays live, read-only views of any tmux pane with full terminal rendering (colors, escape sequences, cursor positioning) via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Events are relayed to paired iOS devices for remote monitoring.

**Primary Use Cases:**
- Monitor long-running processes without leaving your editor
- Display build output or logs on secondary monitors
- Observe remote session activity without attaching
- Create dashboards from multiple tmux panes at once
- **Monitor Claude Code sessions remotely from iOS**
- **Send commands to tmux panes from your iPhone**

## Technology Stack

- **Swift 6.1+** with strict concurrency
- **SwiftUI** for UI (MV pattern, no ViewModels)
- **AppKit** for window management (NSWindow, NSHostingController) - macOS
- **SwiftTerm** for terminal emulation (renders ANSI escape codes) - macOS
- **Swift Concurrency** (async/await, actors, tasks)
- **Named pipes (FIFOs)** for streaming output from tmux
- **CoreText** for precise font metrics calculation
- **CryptoKit** for end-to-end encryption (X25519 ECDH + ChaChaPoly)
- **Vapor** for HTTP hook server and external relay server
- **WebSocket** for real-time Mac ↔ Server ↔ iOS communication (E2EE encrypted)
- **Docker** for external server deployment
- **Caddy** for reverse proxy and TLS termination (production)
- **Testing:** Swift Testing framework with @Test macros

## Project Structure

```
ClaudeSpy/
├── Config/                              # XCConfig build settings
│   ├── Debug.xcconfig
│   ├── Release.xcconfig
│   ├── Shared.xcconfig
│   └── Tests.xcconfig
├── ClaudeSpy.xcworkspace/               # Workspace container
├── ClaudeSpy.xcodeproj/                 # App shell (minimal wrapper)
├── ClaudeSpy/                           # iOS app target entry point
│   └── ClaudeSpyApp.swift               # iOS @main entry point
├── ClaudeSpyServer/                     # macOS app target entry point
│   ├── ClaudeSpyServerApp.swift         # macOS @main entry point
│   └── Assets.xcassets/
├── ClaudeSpyNotificationExtension/      # iOS Notification Service Extension (E2EE decryption)
│   ├── NotificationService.swift        # Decrypts push notification content on-device
│   └── Info.plist
├── ClaudeSpyPackage/                    # All features and business logic
│   ├── Package.swift
│   ├── Sources/
│   │   ├── ClaudeSpyCommon/             # Shared UI utilities (Symbols, extensions)
│   │   ├── ClaudeSpyEncryption/         # E2EE encryption module (Mac/iOS only, not server)
│   │   │   ├── E2EEService.swift        # Key exchange and encrypt/decrypt operations
│   │   │   ├── KeyManager.swift         # Keychain persistence with access group sharing
│   │   │   └── EncryptedPayload.swift   # Encrypted message wrapper
│   │   ├── ClaudeSpyNetworking/         # Platform-agnostic networking models (Mac/Server/iOS)
│   │   │   └── Models/
│   │   │       ├── WebSocketMessage.swift
│   │   │       ├── PairingModels.swift
│   │   │       ├── CommandModels.swift
│   │   │       ├── HookModels.swift
│   │   │       └── RelayMessages.swift
│   │   ├── ClaudeSpyFeature/            # iOS app feature module
│   │   │   ├── Services/                # RelayClient, SessionStore
│   │   │   ├── Views/                   # PairingView, SessionListView, etc.
│   │   │   └── Models/                  # IOSSettings
│   │   ├── ClaudeSpyServerFeature/      # macOS app feature module
│   │   │   ├── Hooks/                   # HookServerService (Vapor)
│   │   │   ├── Services/                # ExternalServerClient, PairingManager
│   │   │   ├── Managers/                # MirrorWindowManager
│   │   │   └── Utilities/               # FontMetrics, ProcessRunner, FIFOReader
│   │   └── ClaudeSpyExternalServer/     # External relay server (Linux-ready)
│   │       ├── main.swift               # Vapor entry point
│   │       ├── Routes/                  # PairingController, WebSocketController
│   │       └── Services/                # PairingService, ConnectionHub, RelayService
│   └── Tests/
├── ClaudeSpyServerTests/                # Unit tests
├── ClaudeSpyServerUITests/              # UI automation tests
├── Dockerfile                           # Multi-stage build for external server
├── docker-compose.yml                   # Production orchestration
├── deploy.sh                            # Deployment script (Hetzner)
├── plugin/                              # Claude Code plugin configuration
│   └── claude-spy/
│       ├── hooks/hooks.json             # Hook event definitions
│       └── scripts/hook.py              # Hook handler script
└── docs/                                # Documentation
    ├── known-issues.md
    ├── swiftterm-sizing.md              # SwiftTerm sizing analysis
    ├── distributed-architecture-plan.md # Full distributed system design
    └── e2ee-encryption-plan.md          # End-to-end encryption design
```

**Module Responsibilities:**
- **ClaudeSpyEncryption** - E2EE cryptographic operations, key management, Keychain persistence (Mac/iOS only)
- **ClaudeSpyNetworking** - Shared message types for Mac ↔ Server ↔ iOS (platform-agnostic)
- **ClaudeSpyServerFeature** - macOS tmux mirroring, hook server, external server client
- **ClaudeSpyFeature** - iOS remote monitoring and command interface
- **ClaudeSpyExternalServer** - Vapor relay server (runs in Docker on Linux, cannot decrypt messages)

**Important:** Development by platform:
- **macOS features**: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/`
- **iOS features**: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/`
- **Shared networking**: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/`
- **Encryption (Mac/iOS)**: `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/`
- **External server**: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/`

## Distributed Architecture

### Data Flows

**Event Flow (Mac → iOS):**
1. Claude Code sends hook event to Mac app (HTTP POST localhost:6111)
2. Mac app processes event locally and updates UI
3. Mac app forwards event to external server via WebSocket
4. External server relays to connected iOS client
5. iOS app displays event in session monitor

**Command Flow (iOS → Mac):**
1. User initiates command in iOS app (e.g., send keystroke)
2. iOS sends command via WebSocket to external server
3. External server relays command to Mac
4. Mac app executes command on appropriate tmux pane

### Device Pairing

Devices are paired using a 6-character code (no user accounts required):
1. Mac app generates code and registers with external server
2. User enters code in iOS app
3. Server validates and creates pair record
4. WebSocket connections established for both devices
5. Code expires after 5 minutes or successful pairing

### Deployment

The external server runs in Docker on Hetzner with Caddy for TLS:
- `deploy.sh` - Builds and deploys to production
- Health endpoint at `/health`
- WebSocket endpoint at `/api/ws`
- Pairing endpoints at `/api/pairing/*`

See `docs/distributed-architecture-plan.md` for full technical details.

### Push Notifications

Push notifications alert iOS users when Claude Code events occur and the iOS app is not connected via WebSocket.

**Architecture:**
- **APNs (Apple Push Notification service)** - Apple's push delivery infrastructure
- **Token-based authentication** - Uses `.p8` key file from Apple Developer Portal
- **VaporAPNS** - Server-side library for sending notifications

**Flow:**
1. iOS app requests notification permission on first launch/pairing
2. iOS receives device token from APNs and sends to server via WebSocket (`registerPushToken`)
3. Server stores token in `PushTokenStore` (persisted to `push-tokens.json`)
4. When Mac sends hook event and iOS is **disconnected**, server sends push via `APNsService`
5. iOS displays notification with event summary

**Events that trigger push notifications:**
- `sessionStart` - "Session Started"
- `sessionEnd` - "Session Ended"
- `permissionRequest` - "Permission Required"
- `stop` - "Session Stopped"
- `notification` (with message) - Custom notification

**Configuration** (in `.env`):
```bash
APNS_KEY_PATH=/secrets/AuthKey.p8   # Path to .p8 key file
APNS_KEY_ID=XXXXXXXXXX              # 10-char key ID from Apple
APNS_TEAM_ID=XXXXXXXXXX             # 10-char team ID
APNS_BUNDLE_ID=com.example.app      # iOS app bundle ID
APNS_ENVIRONMENT=development        # "development" for Xcode, "production" for App Store
```

**Key files:**
- `ClaudeSpyExternalServer/Services/APNsService.swift` - Sends push notifications
- `ClaudeSpyExternalServer/Services/PushTokenStore.swift` - Persists device tokens
- `ClaudeSpyFeature/Services/PushNotificationService.swift` - iOS permission/token handling
- `Config/ClaudeSpy.entitlements` - Contains `aps-environment` entitlement

**Important:** APNs environment must match iOS build type:
- Xcode builds (development signing) → `APNS_ENVIRONMENT=development`
- App Store/TestFlight → `APNS_ENVIRONMENT=production`

### End-to-End Encryption (E2EE)

All sensitive messages between Mac and iOS are end-to-end encrypted. The relay server cannot decrypt message contents - it only routes encrypted payloads.

**Cryptographic Primitives:**
- **Key Exchange:** X25519 ECDH (Elliptic Curve Diffie-Hellman)
- **Symmetric Encryption:** ChaChaPoly (ChaCha20-Poly1305 AEAD)
- **Key Storage:** Keychain with shared access group for Notification Service Extension

**Architecture:**
- `E2EEService` - Handles key pair management, session establishment, encrypt/decrypt
- `KeyManager` - Persists key pairs to Keychain with access group support
- `EncryptedPayload` - Wrapper for ciphertext with sender key ID and version

**Session Establishment Flow:**
1. Mac and iOS generate X25519 key pairs on first launch (persisted to Keychain)
2. Public keys are exchanged during device pairing via the server
3. Each device derives a shared secret using ECDH with partner's public key
4. Session keys are stored in Keychain (shared access group for extension)

**Encrypted Message Types:**
- `hookEvent` - Claude Code session events
- `sessionState` - Active sessions and pane state
- `command` / `commandResponse` - iOS → Mac commands
- `terminalSnapshot` - Terminal content captures

**Unencrypted Message Types** (server needs to process these):
- `registerMac` / `registerIOS` - Device registration with public keys
- `ping` / `pong` - Keep-alive
- `iosConnected` / `iosDisconnected` - Connection state notifications
- `encryptedPush` - Encrypted push payload (server routes, doesn't decrypt)

**Security Properties:**
- **Fail closed:** Clients refuse to send sensitive data if E2EE session not established
- **Server enforcement:** Server rejects unencrypted sensitive message types
- **No fallback:** Encryption failures are logged and messages dropped, never sent plaintext
- **Push encryption:** Push notifications are encrypted; iOS Notification Service Extension decrypts on-device

**Key Files:**
- `ClaudeSpyEncryption/E2EEService.swift` - Core encryption service
- `ClaudeSpyEncryption/KeyManager.swift` - Keychain key persistence
- `ClaudeSpyNotificationExtension/NotificationService.swift` - Push decryption
- `ClaudeSpyNetworking/Models/WebSocketMessage.swift` - `encrypted()` message type

See `docs/e2ee-encryption-plan.md` for full design details.

# Code Quality & Style Guidelines

## Swift Style & Conventions

- **Naming:** Use `UpperCamelCase` for types, `lowerCamelCase` for properties/functions. Choose descriptive names (e.g., `calculateMonthlyRevenue()` not `calcRev`)
- **Value Types:** Prefer `struct` for models and data, use `class` only when reference semantics are required
- **Enums:** Leverage Swift's powerful enums with associated values for state representation
- **Early Returns:** Prefer early return pattern over nested conditionals to avoid pyramid of doom

## SF Symbols Usage

All SF Symbols used in the project must be defined in the `Symbols` enum located at `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift`. This is enforced by SwiftLint to ensure consistency and maintainability.

### How to use SF Symbols:

1. **Never use string literals**: Don't use `Image(systemName: "star.fill")` or `Label("Text", systemImage: "star.fill")`

2. **Add missing symbols to the enum**: If you need a symbol that's not in the enum, add it in alphabetical order:
   ```swift
   @SFSymbol
   public enum Symbols: String {
       case calendar  // For simple names matching the SF Symbol name
       case chartLineUptrendXyaxis = "chart.line.uptrend.xyaxis"  // For complex names
       // ... other symbols in alphabetical order
   }
   ```

3. **Using symbols in SwiftUI views**:
   - **For Image views**: Use `Symbols.star.image` (the macro generates an `.image` property)
     ```swift
     Symbols.starFill.image
     ```
   
   - **For systemImage parameters**: Use the extensions in `ImageExtensions.swift`
     ```swift
     Label("Favorite", symbol: .starFill)
     ContentUnavailableView("No Data", symbol: .exclamationMarkTriangle, description: "No data available")
     ```

4. **Import requirement**: Files using the Symbols enum must import ClaudeSpyCommon:
   ```swift
   import ClaudeSpyCommon
   ```

5. **Naming conventions**:
   - Use camelCase for enum cases
   - For symbols with dots, convert to camelCase: `star.fill` → `starFill`
   - For symbols with special characters, spell them out: `exclamationmark.triangle` → `exclamationMarkTriangle`

## Optionals & Error Handling

- Use optionals with `if let`/`guard let` for nil handling
- Never force-unwrap (`!`) without absolute certainty - prefer `guard` with failure path
- Use `do/try/catch` for error handling with meaningful error types
- Handle or propagate all errors - no empty catch blocks

# Modern SwiftUI Architecture Guidelines (2025)

### No ViewModels - Use Native SwiftUI Data Flow
**New features MUST follow these patterns:**

1. **Views as Pure State Expressions**
   ```swift
   struct MyView: View {
       @Environment(MyService.self) private var service
       @State private var viewState: ViewState = .loading
       
       enum ViewState {
           case loading
           case loaded(data: [Item])
           case error(String)
       }
       
       var body: some View {
           // View is just a representation of its state
       }
   }
   ```

2. **Use Environment Appropriately**
   - **App-wide services**: Router, Theme, CurrentAccount, Client, etc. - use `@Environment`
   - **Feature-specific services**: Timeline services, single-view logic - use `let` properties with `@Observable`
   - Rule: Environment for cross-app/cross-feature dependencies, let properties for single-feature services
   - Access app-wide via `@Environment(ServiceType.self)`
   - Feature services: `private let myService = MyObservableService()`

3. **Local State Management**
   - Use `@State` for view-specific state
   - Use `enum` for view states (loading, loaded, error)
   - Use `.task(id:)` and `.onChange(of:)` for side effects
   - Pass state between views using `@Binding`

4. **No ViewModels Required**
   - Views should be lightweight and disposable
   - Business logic belongs in services/clients
   - Test services independently, not views
   - Use SwiftUI previews for visual testing

5. **When Views Get Complex**
   - Split into smaller subviews
   - Use compound views that compose smaller views
   - Pass state via bindings between views
   - Never reach for a ViewModel as the solution

# Core Architecture

## Key Services

### TmuxService (`Services/TmuxService.swift`)
`@Observable @MainActor` class that abstracts all tmux CLI interactions.

**Responsibilities:**
- Execute tmux commands via `ProcessRunner` with proper socket path handling
- Enumerate panes: `listPanes()` discovers all panes across sessions
- Validate panes: `validatePane()` checks if a pane target exists
- Capture content:
  - `capturePane()` - captures full scrollback with ANSI escape sequences
  - `capturePaneWithPositioning()` - captures with cursor positioning for proper alignment
- Stream setup: `startPipePipe()` / `stopPipePipe()` manages FIFOs for live streaming
- Track dimensions: `getPaneDimensions()` and `getPaneId()`

**Configuration:** Takes `tmuxPath` (default: `/opt/homebrew/bin/tmux`) and optional `socketPath`.

### PaneStream (`Services/PaneStream.swift`)
`@Observable @MainActor` class managing streaming connection to a single tmux pane.

**States:** `disconnected` → `connecting` → `connected` | `paused` | `error`

**Data Flow:**
```
TmuxService.startPipePipe() ──▶ FIFOReader ──▶ AsyncStream<Data>
                                                     ║
                                                     ▼
                                     PaneStream buffers or yields
                                                     ║
                                                     ▼
                                      TerminalController.feed(data)
```

**Features:**
- Initial content delivery with cursor positioning on connect
- Pause/resume with buffering (`pauseBuffer: [Data]`)
- Dimension tracking for terminal sizing

### MirrorWindowManager (`Managers/MirrorWindowManager.swift`)
`@Observable @MainActor` class managing lifecycle of NSWindow instances.

**Responsibilities:**
- Create windows sized to pane dimensions using `FontMetrics` for precise calculation
- Track windows by pane target: `[String: NSWindow]`
- Reuse existing windows (bring to front vs. duplicate)
- Support programmatic open/close via `HookServerService`

### TerminalController (`Views/TerminalContainerView.swift`)
`@Observable @MainActor` class bridging SwiftTerm to SwiftUI.

**Key Features:**
- Wraps SwiftTerm's `TerminalView` (native terminal emulation)
- Uses **FlippedClipView** to align content to top (not bottom)
- Fixed terminal dimensions in character cells matching pane size
- Precise cell size calculation via CoreText font metrics
- Theme support (DefaultDark/Light, SolarizedDark/Light)
- Scroll tracking for "Jump to Bottom" functionality

### HookServerService (`Hooks/HookServerService.swift`)
`@Observable @MainActor` class running a Vapor HTTP server on port 6111.

**Purpose:** Receives Claude Code hook events and automatically manages mirror windows.

**Supported Events:**
- `SessionStart` - Auto-opens mirror for the tmux pane where Claude Code started
- `SessionEnd` - Auto-closes the corresponding mirror window
- `NotificationSend` - Receives notification events (for future use)
- `Stop` - Handles Claude Code stop events

**Integration:** The Claude Code plugin (`plugin/claude-spy/`) sends HTTP POST requests to the hook server when events occur. See `hooks/hooks.json` for event configuration.

### ExternalServerClient (`Services/ExternalServerClient.swift`) - macOS
`@Observable @MainActor` class managing WebSocket connection to the external relay server.

**Responsibilities:**
- Connect/disconnect to external server with pairId
- Send `WebSocketMessage` to server for relay to iOS
- Handle incoming messages (commands from iOS, connection state)
- Track iOS connection status

### PairingManager (`Services/PairingManager.swift`) - macOS
`@Observable @MainActor` class managing device pairing lifecycle.

**States:** `unpaired` → `generatingCode` → `waitingForPairing` → `paired`

**Responsibilities:**
- Generate 6-character pairing codes
- Register codes with external server
- Poll for pairing completion
- Persist pairing info to UserDefaults

### RelayClient (`Services/RelayClient.swift`) - iOS
`@Observable @MainActor` class managing WebSocket connection from iOS to server.

**Responsibilities:**
- Connect to server after pairing
- Receive session state and hook events from Mac
- Send commands (keystroke, cancel) to Mac
- Auto-reconnection with exponential backoff

### SessionStore (`Services/SessionStore.swift`) - iOS
`@Observable @MainActor` class tracking Claude sessions received from Mac.

**Responsibilities:**
- Store active sessions by pane ID
- Handle incoming hook events
- Update session state on full sync
- Clear state on disconnect

## Utilities

### FontMetrics (`Utilities/FontMetrics.swift`)
Utility enum for calculating terminal font metrics matching SwiftTerm's internal calculations.

- `calculateCellSize(fontName:fontSize:)` - Returns cell dimensions using CoreText
- `swiftTermScrollerWidth` - Dynamic calculation of SwiftTerm's internal scroller width
- `horizontalBuffer` - Compensation for SwiftTerm's scroller (scroller width + 4px)

See `docs/swiftterm-sizing.md` for detailed analysis of SwiftTerm's sizing behavior.

### FIFOReader (`Utilities/FIFOReader.swift`)
Actor for managing named pipes (FIFOs) to receive streaming tmux output.

- `createFIFO()` - Creates named pipe via `mkfifo()`
- `startReading()` - Returns `AsyncStream<Data>` from FIFO
- Handles EOF gracefully (tmux may reopen the pipe)

**Why FIFOs?** Tmux's `pipe-pane` pipes output to a command. ClaudeSpy uses `cat > /tmp/tmux-mirror-{uuid}.fifo`, then reads that FIFO for continuous streaming.

### ProcessRunner (`Utilities/ProcessRunner.swift`)
Actor for executing external processes (tmux commands).

- Runs processes asynchronously, collects stdout/stderr
- Thread-safe `OutputCollector` using NSLock
- Returns `ProcessResult` with exit code, stdout, stderr

## Key Models

### PaneInfo (`Models/PaneInfo.swift`)
Represents a discovered tmux pane:
- `id`, `target`, `sessionName`, `windowIndex`, `paneIndex`
- `command`, `currentPath`, `width`, `height`, `isActive`

### AppSettings (`Models/Settings.swift`)
`@Observable @MainActor` with UserDefaults persistence:
- **Terminal:** `fontName`, `fontSize`, `scrollbackLines`, `theme`
- **Behavior:** `restoreWindowsOnLaunch`, `showStatusBar`, `autoReconnect`
- **Tmux:** `tmuxPath`, `tmuxSocket`

## Key Patterns

### Cursor Positioning Strategy
`capturePaneWithPositioning()` generates ANSI escape sequences to position each line:
```swift
positionedContent += "\u{1b}[H"  // Home
for (index, line) in lines {
    positionedContent += "\u{1b}[\(index + 1);1H"  // Row, column 1
    positionedContent += "\u{1b}[2K"  // Clear line
    positionedContent += line
}
positionedContent += "\u{1b}[\(cursorY + 1);\(cursorX + 1)H"  // Final cursor position
```

### FlippedClipView
Custom `NSClipView` subclass with `isFlipped = true` to align terminal content to top instead of bottom (AppKit default is origin at bottom-left).

### Actor-Based Concurrency
- `TmuxService`, `PaneStream` - `@Observable @MainActor` (UI-bound)
- `ProcessRunner`, `FIFOReader` - actors (background I/O)

## SwiftUI State Management (MV Pattern)

- **@State:** For all state management, including observable model objects
- **@Observable:** Modern macro for making model classes observable (replaces ObservableObject)
- **@Environment:** For dependency injection and shared app state
- **@Binding:** For two-way data flow between parent and child views
- **@Bindable:** For creating bindings to @Observable objects
- Avoid ViewModels - put view logic directly in SwiftUI views using these state mechanisms
- Keep views focused and extract reusable components

Example with @Observable:
```swift
@Observable
class UserSettings {
    var theme: Theme = .light
    var fontSize: Double = 16.0
}

@MainActor
struct SettingsView: View {
    @State private var settings = UserSettings()
    
    var body: some View {
        VStack {
            // Direct property access, no $ prefix needed
            Text("Font Size: \(settings.fontSize)")
            
            // For bindings, use @Bindable
            @Bindable var settings = settings
            Slider(value: $settings.fontSize, in: 10...30)
        }
    }
}

// Sharing state across views
@MainActor
struct ContentView: View {
    @State private var userSettings = UserSettings()
    
    var body: some View {
        NavigationStack {
            MainView()
                .environment(userSettings)
        }
    }
}

@MainActor
struct MainView: View {
    @Environment(UserSettings.self) private var settings
    
    var body: some View {
        Text("Current theme: \(settings.theme)")
    }
}
```

Example with .task modifier for async operations:
```swift
@Observable
class DataModel {
    var items: [Item] = []
    var isLoading = false
    
    func loadData() async throws {
        isLoading = true
        defer { isLoading = false }
        
        // Simulated network call
        try await Task.sleep(for: .seconds(1))
        items = try await fetchItems()
    }
}

@MainActor
struct ItemListView: View {
    @State private var model = DataModel()
    
    var body: some View {
        List(model.items) { item in
            Text(item.name)
        }
        .overlay {
            if model.isLoading {
                ProgressView()
            }
        }
        .task {
            // This task automatically cancels when view disappears
            do {
                try await model.loadData()
            } catch {
                // Handle error
            }
        }
        .refreshable {
            // Pull to refresh also uses async/await
            try? await model.loadData()
        }
    }
}
```

## Concurrency

- **@MainActor:** All UI updates must use @MainActor isolation
- **Actors:** Use actors for expensive operations like disk I/O, network calls, or heavy computation
- **async/await:** Always prefer async functions over completion handlers
- **Task:** Use structured concurrency with proper task cancellation
- **.task modifier:** Always use .task { } on views for async operations tied to view lifecycle - it automatically handles cancellation
- **Avoid Task { } in onAppear:** This doesn't cancel automatically and can cause memory leaks or crashes
- No GCD usage - Swift Concurrency only

### Sendable Conformance

Swift 6 enforces strict concurrency checking. All types that cross concurrency boundaries must be Sendable:

- **Value types (struct, enum):** Usually Sendable if all properties are Sendable
- **Classes:** Must be marked `final` and have immutable or Sendable properties, or use `@unchecked Sendable` with thread-safe implementation
- **@Observable classes:** Automatically Sendable when all properties are Sendable
- **Closures:** Mark as `@Sendable` when captured by concurrent contexts

```swift
// Sendable struct - automatic conformance
struct UserData: Sendable {
    let id: UUID
    let name: String
}

// Sendable class - must be final with immutable properties
final class Configuration: Sendable {
    let apiKey: String
    let endpoint: URL
    
    init(apiKey: String, endpoint: URL) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }
}

// @Observable with Sendable
@Observable
final class UserModel: Sendable {
    var name: String = ""
    var age: Int = 0
    // Automatically Sendable if all stored properties are Sendable
}

// Using @unchecked Sendable for thread-safe types
final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    
    func get(_ key: String) -> Any? {
        lock.withLock { storage[key] }
    }
}

// @Sendable closures
func processInBackground(completion: @Sendable @escaping (Result<Data, Error>) -> Void) {
    Task {
        // Processing...
        completion(.success(data))
    }
}
```

## Code Organization

- Keep functions focused on a single responsibility
- Break large functions (>50 lines) into smaller, testable units
- Use extensions to organize code by feature or protocol conformance
- Prefer `let` over `var` - use immutability by default
- Use `[weak self]` in closures to prevent retain cycles
- Always include `self.` when referring to instance properties in closures

# Testing Guidelines

We use **Swift Testing** framework (not XCTest) for all tests. Tests live in the package test target.

## Swift Testing Basics

```swift
import Testing

@Test func userCanLogin() async throws {
    let service = AuthService()
    let result = try await service.login(username: "test", password: "pass")
    #expect(result.isSuccess)
    #expect(result.user.name == "Test User")
}

@Test("User sees error with invalid credentials")
func invalidLogin() async throws {
    let service = AuthService()
    await #expect(throws: AuthError.self) {
        try await service.login(username: "", password: "")
    }
}
```

## Key Swift Testing Features

- **@Test:** Marks a test function (replaces XCTest's test prefix)
- **@Suite:** Groups related tests together
- **#expect:** Validates conditions (replaces XCTAssert)
- **#require:** Like #expect but stops test execution on failure
- **Parameterized Tests:** Use @Test with arguments for data-driven tests
- **async/await:** Full support for testing async code
- **Traits:** Add metadata like `.bug()`, `.feature()`, or custom tags

## Test Organization

- Write tests in the package's Tests/ directory
- One test file per source file when possible
- Name tests descriptively explaining what they verify
- Test both happy paths and edge cases
- Add tests for bug fixes to prevent regression

# Entitlements Management

This template includes a **declarative entitlements system** that AI agents can safely modify without touching Xcode project files.

## How It Works

- **Entitlements File**: `Config/ClaudeSpy.entitlements` contains all app capabilities
- **XCConfig Integration**: `CODE_SIGN_ENTITLEMENTS` setting in `Config/Shared.xcconfig` points to the entitlements file
- **AI-Friendly**: Agents can edit the XML file directly to add/remove capabilities

## Adding Entitlements

To add capabilities to your app, edit `Config/ClaudeSpy.entitlements`:

## Common Entitlements

| Capability | Entitlement Key | Value |
|------------|-----------------|-------|
| HealthKit | `com.apple.developer.healthkit` | `<true/>` |
| CloudKit | `com.apple.developer.icloud-services` | `<array><string>CloudKit</string></array>` |
| Push Notifications | `aps-environment` | `development` or `production` |
| App Groups | `com.apple.security.application-groups` | `<array><string>group.id</string></array>` |
| Keychain Sharing | `keychain-access-groups` | `<array><string>$(AppIdentifierPrefix)bundle.id</string></array>` |
| Background Modes | `com.apple.developer.background-modes` | `<array><string>mode-name</string></array>` |
| Contacts | `com.apple.developer.contacts.notes` | `<true/>` |
| Camera | `com.apple.developer.avfoundation.audio` | `<true/>` |

# Building & Testing

Use the `XcodeBuildTools` skills for building and testing.

# Development Workflow

1. **Choose the right module**:
   - macOS features → `ClaudeSpyServerFeature`
   - iOS features → `ClaudeSpyFeature`
   - Shared networking → `ClaudeSpyNetworking`
   - Encryption (Mac/iOS) → `ClaudeSpyEncryption`
   - External server → `ClaudeSpyExternalServer`
2. **Write tests**: Add Swift Testing tests in `ClaudeSpyPackage/Tests/`
3. **Build and test**: Use XcodeBuildTools skills to build and run tests
4. **Test locally**:
   - macOS app: Build and launch to test against live tmux sessions
   - iOS app: Run in simulator, pair with Mac app
   - External server: Run with `docker-compose up` or `swift run`
5. **Deploy server changes**: Use `./deploy.sh` to push to production
6. **Check known issues**: See `docs/known-issues.md` for documented edge cases
7. **Architecture reference**: See `docs/distributed-architecture-plan.md` for system design

# Best Practices

## SwiftUI & State Management

- Keep views small and focused
- Extract reusable components into their own files
- Use @ViewBuilder for conditional view composition
- Leverage SwiftUI's built-in animations and transitions
- Avoid massive body computations - break them down
- **Always use .task modifier** for async work tied to view lifecycle - it automatically cancels when the view disappears
- Never use Task { } in onAppear - use .task instead for proper lifecycle management

## Performance

- Use .id() modifier sparingly as it forces view recreation
- Implement Equatable on models to optimize SwiftUI diffing
- Use LazyVStack/LazyHStack for large lists
- Profile with Instruments when needed
- @Observable tracks only accessed properties, improving performance over @Published

## AppKit Integration (macOS-Specific)

- Use `NSHostingController` to embed SwiftUI views in NSWindow
- Use `NSViewRepresentable` for wrapping AppKit views (like SwiftTerm's TerminalView)
- Remember AppKit's coordinate system has origin at bottom-left (use `isFlipped` when needed)
- Manage window lifecycle explicitly via NSWindowDelegate
- Use `setFrameAutosaveName` for persistent window positions

## Terminal Rendering

- SwiftTerm handles ANSI escape sequence parsing and rendering
- Feed raw Data directly - don't convert to String first (preserves encoding)
- Match terminal dimensions to tmux pane dimensions in character cells
- Use CoreText font metrics for precise cell size calculation
- Always use cursor positioning commands when rendering initial content

## Settings & Persistence

This app uses **UserDefaults** for settings persistence via the `AppSettings` class:
- Settings are simple key-value pairs (fonts, paths, booleans)
- Use `@Observable` with `@didSet` for reactive persistence
- No SwiftData needed - all state is transient or UserDefaults-based

---

Remember: This is a distributed system across three platforms. Keep app shells minimal and implement all features in the Swift Package modules. The complexity lies in:
- **macOS**: Process management, I/O streaming, terminal rendering, E2EE encryption
- **External Server**: WebSocket relay, device pairing, connection tracking (blind to message content)
- **iOS**: Remote monitoring, command dispatch, state synchronization, E2EE decryption

For full architectural details, see `docs/distributed-architecture-plan.md` and `docs/e2ee-encryption-plan.md`.