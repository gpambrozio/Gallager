# Project Overview

**ClaudeSpy** (Tmux Pane Mirror) is a native **macOS application** that displays real-time mirrors of tmux panes in native windows. Built with **Swift 6.1+** and **SwiftUI**, targeting **macOS 15.0+**. All concurrency is handled with **Swift Concurrency** (async/await, actors, @MainActor isolation).

## What This App Does

Instead of attaching to a tmux session directly in the terminal, users can open dedicated windows that show live, read-only views of any tmux pane with full terminal rendering (colors, escape sequences, cursor positioning) via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

**Primary Use Cases:**
- Monitor long-running processes without leaving your editor
- Display build output or logs on secondary monitors
- Observe remote session activity without attaching
- Create dashboards from multiple tmux panes at once

## Technology Stack

- **Swift 6.1+** with strict concurrency
- **SwiftUI** for UI (MV pattern, no ViewModels)
- **AppKit** for window management (NSWindow, NSHostingController)
- **SwiftTerm** for terminal emulation (renders ANSI escape codes)
- **Swift Concurrency** (async/await, actors, tasks)
- **Named pipes (FIFOs)** for streaming output from tmux
- **CoreText** for precise font metrics calculation
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
├── ClaudeSpy/                           # iOS target (unused currently)
├── ClaudeSpyServer/                     # macOS app target entry point
│   ├── ClaudeSpyServerApp.swift         # @main entry point
│   └── Assets.xcassets/
├── ClaudeSpyPackage/                    # All features and business logic
│   ├── Package.swift
│   ├── Sources/
│   │   ├── ClaudeSpyCommon/             # Shared UI utilities (Symbols, extensions)
│   │   ├── ClaudeSpyFeature/            # Generic features (less used)
│   │   └── ClaudeSpyServerFeature/      # Main tmux mirroring implementation
│   └── Tests/
├── ClaudeSpyServerTests/                # Unit tests
├── ClaudeSpyServerUITests/              # UI automation tests
└── docs/                                # Documentation
    └── known-issues.md
```

**Important:** All development work should be done in **ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/**. The app target is merely a thin wrapper.

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
- Create windows sized to pane dimensions (7.2pt/char width, 14pt height)
- Track windows by pane target: `[String: NSWindow]`
- Reuse existing windows (bring to front vs. duplicate)
- Auto-save window frames per pane: `MirrorWindow-{target}`

### TerminalController (`Views/TerminalContainerView.swift`)
`@Observable @MainActor` class bridging SwiftTerm to SwiftUI.

**Key Features:**
- Wraps SwiftTerm's `TerminalView` (native terminal emulation)
- Uses **FlippedClipView** to align content to top (not bottom)
- Fixed terminal dimensions in character cells matching pane size
- Precise cell size calculation via CoreText font metrics
- Theme support (DefaultDark/Light, SolarizedDark/Light)
- Scroll tracking for "Jump to Bottom" functionality

## Utilities

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

Use the `XcodeBuildTools` skills for building and testing. The scheme is `ClaudeSpyServer` for the macOS app.

## Build Commands

```bash
# Build for macOS (via skill)
/XcodeBuildTools:xcodebuild build --workspace ClaudeSpy.xcworkspace --scheme ClaudeSpyServer

# Run tests
/XcodeBuildTools:xcode-test --workspace ClaudeSpy.xcworkspace --scheme ClaudeSpyServer

# Test Swift Package directly
/XcodeBuildTools:swift-package test --path ClaudeSpyPackage
```

## Running the App

After building, the macOS app can be launched:
```bash
/XcodeBuildTools:macos-app launch --app-path /path/to/ClaudeSpyServer.app
```

# Development Workflow

1. **Make changes in the Package**: All feature development happens in `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/`
2. **Write tests**: Add Swift Testing tests in `ClaudeSpyPackage/Tests/`
3. **Build and test**: Use XcodeBuildTools skills to build and run tests
4. **Run the app**: Build and launch to test against live tmux sessions
5. **Check known issues**: See `docs/known-issues.md` for documented edge cases

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

Remember: This is a macOS utility app. Keep the app shell minimal and implement all features in the Swift Package. The complexity lies in process management, I/O streaming, and terminal rendering - not in data persistence.