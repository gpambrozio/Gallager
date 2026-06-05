# ClaudeSpy

Distributed system for monitoring coding-agent sessions (Anthropic Claude Code and OpenAI Codex CLI, behind a shared `CodingAgent` abstraction in `ClaudeSpyNetworking`). Three components:
1. **Mac App** - tmux pane mirroring, receives hooks from both agents, forwards to server
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
├── ClaudeSpyPackage/              # ALL business logic + server deployment
│   ├── Sources/
│   │   ├── ClaudeSpyCommon/       # Shared UI (Symbols, extensions)
│   │   ├── ClaudeSpyEncryption/   # E2EE (Mac/iOS only)
│   │   ├── ClaudeSpyNetworking/   # Shared models (Mac/Server/iOS)
│   │   ├── ClaudeSpyFeature/      # iOS feature module
│   │   ├── ClaudeSpyServerFeature/  # macOS feature module
│   │   └── ClaudeSpyExternalServer/ # Vapor relay server
│   ├── Dockerfile                 # Server container build
│   ├── docker-compose.yml         # Server orchestration
│   └── caddy/                     # Reverse proxy configs
└── docs/                          # Architecture docs
```

**Development by platform:**
- macOS → `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/`
- iOS → `ClaudeSpyPackage/Sources/ClaudeSpyFeature/`
- Shared → `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/`
- Encryption → `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/`
- Server → `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/`

## Critical Rules

### Only necessary code outside Packages

The code in the Xcode project should be the absolute minimal. If code can be in a package then it should. 

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
- actors for I/O (ProcessRunner, TmuxControlClient)
- No GCD, Swift Concurrency only
- All cross-boundary types must be `Sendable`

### Dependencies (Dependency Injection)

Use [Point-Free Dependencies](https://github.com/pointfreeco/swift-dependencies) for services that wrap system APIs or perform I/O. This enables testability without real system interaction.

**When to use `@DependencyClient`:**
- Stateless utilities wrapping system APIs (UserDefaults, Keychain, SMAppService, IOKit, etc.)
- Process execution and filesystem access
- Services that are hard to test without mocking (network, push notifications)

**When NOT to use it:**
- `@Observable` classes with complex state and many wired callbacks (use init injection instead)
- Services already using Vapor's DI container (external server)
- Simple value types or pure functions

**Pattern:** Define as `@DependencyClient struct`, conform to `DependencyKey`, provide `liveValue` and optional `inMemory()`. See `docs/swift-patterns.md` for full examples.

**Usage in `@Observable` classes:**
```swift
@ObservationIgnored
@Dependency(MyService.self) private var myService
```

**Usage in initializers:**
```swift
@Dependency(MyService.self) var service
```

**Testing:**
```swift
try await withDependencies {
    $0[MyService.self] = .testValue
} operation: {
    // code under test
}
```

### Error Handling

- `guard let` / `if let` for optionals
- No force-unwrap without certainty
- `do/try/catch` with meaningful errors
- No empty catch blocks

## Building & Testing

Use XcodeBuildTools skills. Scheme: `ClaudeSpyServer` (macOS), `ClaudeSpy` (iOS).

**Killing Mac app:** Use `osascript -e 'quit app "Gallager"'` — `pkill`/`killall` don't work reliably.

**Opening a PR:** A `PostToolUse` hook (`.claude/hooks/pr-checklist.py`) fires on `gh pr create` and injects a checklist of post-PR chores (docs, CLAUDE.md, CLI/`gallager`-skill, e2e scenarios). Work through it before stopping. See `docs/repo-hooks.md`.

## Reference Docs

- **Code examples:** `docs/swift-patterns.md` - SwiftUI patterns, Sendable, Dependencies, testing
- **Services:** `docs/services-reference.md` - TmuxService, PaneStream, CodingAgent, project scanners, etc.
- **Architecture:** `docs/architecture.md` (Mac app) and `docs/distributed-architecture-plan.md` (Mac/Server/iOS)
- **Codex CLI integration:** `docs/codex-cli-integration-plan.md` - `CodingAgent` abstraction, hook bridge, project discovery
- **Encryption:** `docs/e2ee-encryption-plan.md`
- **E2E testing:** `docs/e2e-testing.md` - Test framework, running tests, writing scenarios
- **Self-hosting:** `docs/self-hosting.md` - Deploy your own relay server
- **Repo hooks:** `docs/repo-hooks.md` - Project-scoped Claude Code hooks (swiftformat, PR checklist)
- **Known issues:** `docs/known-issues.md`
- **Terminal sizing (macOS):** `docs/swiftterm-sizing.md`
- **Terminal scrolling (iOS):** `docs/swiftterm-ios-scrolling.md`
- **Terminal rendering bugs:** `docs/terminal-rendering-investigation.md` - Hypotheses, test results, fix priorities
