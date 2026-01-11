# ClaudeSpy

Distributed system for monitoring Claude Code sessions. Three components:
1. **Mac App** - tmux pane mirroring, receives hooks, forwards to server
2. **External Server** - Vapor relay (Docker/Linux), device pairing, WebSocket routing
3. **iOS App** - Remote monitoring, command dispatch

**Stack:** Swift 6.1+, SwiftUI (MV pattern), Swift Concurrency, SwiftTerm, Vapor, CryptoKit (E2EE)

**Targets:** macOS 15.0+, iOS 17.0+

## Project Structure

```
ClaudeSpy/
├── Config/                        # XCConfig (Debug/Release/Shared/Tests.xcconfig)
├── ClaudeSpy/                     # iOS @main entry
├── ClaudeSpyServer/               # macOS @main entry
├── ClaudeSpyNotificationExtension/  # iOS push decryption extension
├── ClaudeSpyPackage/              # ALL business logic
│   └── Sources/
│       ├── ClaudeSpyCommon/       # Shared UI (Symbols, extensions)
│       ├── ClaudeSpyEncryption/   # E2EE (Mac/iOS only)
│       ├── ClaudeSpyNetworking/   # Shared models (Mac/Server/iOS)
│       ├── ClaudeSpyFeature/      # iOS feature module
│       ├── ClaudeSpyServerFeature/  # macOS feature module
│       └── ClaudeSpyExternalServer/ # Vapor relay server
├── Dockerfile, docker-compose.yml, deploy.sh
└── docs/                          # Architecture docs
```

**Development by platform:**
- macOS → `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/`
- iOS → `ClaudeSpyPackage/Sources/ClaudeSpyFeature/`
- Shared → `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/`
- Encryption → `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/`
- Server → `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/`

## Critical Rules

### No ViewModels

Use native SwiftUI data flow:
- `@State` for view-specific state
- `@Observable` for model classes
- `@Environment` for app-wide services
- `@Binding` / `@Bindable` for two-way flow
- `.task` for async (auto-cancels), never `Task {}` in `onAppear`

### SF Symbols

Never use string literals. Add to `ClaudeSpyCommon/UI/Symbols.swift`:
```swift
@SFSymbol
public enum Symbols: String {
    case starFill = "star.fill"
}
```
Use: `Symbols.starFill.image` or `Label("Text", symbol: .starFill)`

### Concurrency

- `@MainActor` for all UI
- actors for I/O (ProcessRunner, FIFOReader)
- No GCD, Swift Concurrency only
- All cross-boundary types must be `Sendable`

### Error Handling

- `guard let` / `if let` for optionals
- No force-unwrap without certainty
- `do/try/catch` with meaningful errors
- No empty catch blocks

## Building & Testing

Use XcodeBuildTools skills. Scheme: `ClaudeSpyServer` (macOS), `ClaudeSpy` (iOS).

## Reference Docs

- **Code examples:** `docs/swift-patterns.md` - SwiftUI patterns, Sendable, testing
- **Services:** `docs/services-reference.md` - TmuxService, PaneStream, etc.
- **Architecture:** `docs/distributed-architecture-plan.md`
- **Encryption:** `docs/e2ee-encryption-plan.md`
- **Known issues:** `docs/known-issues.md`
- **Terminal sizing:** `docs/swiftterm-sizing.md`
