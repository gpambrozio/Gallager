# E2E Testing

End-to-end tests verify the full ClaudeSpy system: macOS app, iOS simulator app, and an in-process Vapor relay server running together on localhost.

## Architecture

```
ClaudeSpyPackage/Sources/
├── ClaudeSpyE2E/              # CLI entry point (ArgumentParser)
│   └── ClaudeSpyE2ECommand.swift
└── ClaudeSpyE2ELib/           # Test framework library
    ├── DSL/                   # Scenario definition
    │   ├── TestScenario.swift # TestStep enum + TestScenario struct
    │   └── ScenarioBuilder.swift  # @resultBuilder for declarative scenarios
    ├── Drivers/               # Platform-specific automation
    │   ├── MacOS/             # AppleScript via osascript + ProcessRunner
    │   ├── Server/            # In-process Vapor server lifecycle
    │   └── Simulator/         # simctl, Accessibility tree, coordinate mapping
    ├── Orchestrator/          # Step execution + cleanup
    │   ├── TestOrchestrator.swift
    │   └── ExecutionContext.swift  # Variable storage between steps
    ├── Scenarios/             # Test scenario definitions
    └── Utilities/             # ProcessRunner, Polling helpers
```

### How it works

1. **ClaudeSpyE2ECommand** parses CLI args and creates a `TestOrchestrator`
2. **TestOrchestrator** runs scenarios sequentially, executing each `TestStep` via the appropriate driver
3. **Drivers** handle platform interaction:
   - **SimulatorDriver** — boots simulator, installs/launches apps, reads AX tree, taps elements, types text
   - **MacOSDriver** — launches macOS app, clicks buttons via AppleScript (`osascript`), takes screenshots
   - **ServerDriver** — starts/stops an in-process Vapor server, checks health and pairing state
4. After each scenario, the orchestrator runs **cleanup** (terminate both apps, stop server) regardless of pass/fail

### Storage isolation

Both apps accept `--e2e-test` as a launch argument. When present, `prepareDependencies` (swift-dependencies) overrides `PreferencesService` and `SecretsService` with in-memory implementations. This prevents E2E tests from writing to real UserDefaults or Keychain.

### Tmux socket isolation

The macOS app accepts `--tmux-socket <path>` (alongside `--e2e-test`) to use a dedicated tmux server socket instead of the system default. This prevents E2E tests from polluting the developer's real tmux sessions. The default socket path is `/tmp/claudespy-e2e.sock`. During cleanup, the orchestrator kills the isolated tmux server and removes the socket file.

### Variable interpolation

Steps can pass data between each other via `ExecutionContext`. Use `macReadClipboard(storeAs: "key")` or `storeValue(key:value:)` to store, and `"${key}"` in any string argument to reference it. The orchestrator resolves variables before passing to drivers.

## Running tests

### Using the script (recommended)

```bash
# Build everything and run all scenarios
./scripts/e2e-test.sh

# Skip build, just run tests with previously built artifacts
./scripts/e2e-test.sh --skip-build

# Run with a specific simulator
./scripts/e2e-test.sh --sim-name "iPhone 16 Pro"

# Other options
./scripts/e2e-test.sh --screenshots /path/to/dir

# Interactive mode: launch all apps and wait (no pairing)
./scripts/e2e-test.sh --skip-build --interactive

# Interactive mode: run a scenario then wait
./scripts/e2e-test.sh --skip-build --interactive --scenario "Fresh Pairing"

# Custom tmux socket path
./scripts/e2e-test.sh --tmux-socket /tmp/my-test.sock
```

### Running manually

Build all three targets first (macOS app, iOS app, E2E coordinator), then:

```bash
ClaudeSpyE2E \
    --ios-app-path /path/to/ClaudeSpy.app \
    --macos-app-path /path/to/ClaudeSpyServer.app \
    --sim-name "iPhone 17 Pro" \
    --screenshots-dir /tmp/e2e-screenshots \
    --tmux-socket /tmp/claudespy-e2e.sock
```

### Running a specific scenario

```bash
./scripts/e2e-test.sh --skip-build  # then manually:
ClaudeSpyE2E --scenario "Fresh Pairing" ...
```

### Prerequisites

- Xcode with iOS Simulator installed
- The simulator named in `--sim-name` must exist (`xcrun simctl list devices available`)
- Accessibility permissions for Terminal/IDE (System Settings > Privacy > Accessibility)
- `xcsift` installed (`brew install xcsift`) for build output filtering

## Writing scenarios

### Basic scenario

Create a new file in `ClaudeSpyE2ELib/Scenarios/`:

```swift
import Foundation

public enum MyScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "My Scenario",
        tags: ["mytag"]
    ) {
        TestStep.startServer(port: 8_765)
        TestStep.verifyServerHealth

        TestStep.launchIOSApp(arguments: ["--e2e-test", "--server-url", "ws://127.0.0.1:8765"])
        TestStep.iosWaitForElement(.labelContains("some text"), timeout: 10)
        TestStep.iosScreenshot(label: "my-screenshot")

        TestStep.launchMacApp(arguments: ["--e2e-test", "--server-url", "ws://127.0.0.1:8765"])
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-screenshot")
    }
}
```

### Composing scenarios

Scenarios can include other scenarios. Their steps get flattened inline:

```swift
public enum AdvancedScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Advanced Test",
        tags: ["advanced"]
    ) {
        // All pairing steps run first
        FreshPairingScenario.scenario

        // Then additional steps with both apps paired and running
        TestStep.iosTap(.label("New Session"))
        TestStep.wait(seconds: 2)
        TestStep.iosTap(.labelContains("New Terminal"))
    }
}
```

Scenarios should **not** include cleanup steps (terminate apps, stop server) — the orchestrator handles that automatically after each scenario.

### Registering a scenario

Add it to the `allScenarios` array in `ClaudeSpyE2ECommand.swift`:

```swift
private static let allScenarios: [TestScenario] = [
    FreshPairingScenario.scenario,
    NewTerminalScenario.scenario,
    MyScenario.scenario,  // add here
]
```

## Available test steps

### Server

| Step | Description |
|------|-------------|
| `startServer(port:)` | Start the in-process Vapor relay server |
| `verifyServerHealth` | Wait for the server health endpoint to respond |
| `verifyServerHasPairings(count:)` | Assert the number of active pairings |
| `waitForHostConnected(timeout:)` | Wait for the macOS host to connect via WebSocket |
| `stopServer` | Stop the server and clean up `pairs.json` |

### iOS Simulator

| Step | Description |
|------|-------------|
| `launchIOSApp(arguments:)` | Boot simulator, install, and launch the iOS app |
| `terminateIOSApp` | Terminate the running iOS app |
| `uninstallIOSApp` | Terminate and uninstall the iOS app |
| `iosWaitForElement(_:timeout:)` | Wait for a UI element matching an `ElementQuery` |
| `iosTap(_:)` | Wait for and tap a UI element |
| `iosTapCoordinate(x:y:)` | Tap at raw iOS point coordinates |
| `iosType(text:)` | Type text (supports `${variable}` interpolation) |
| `iosScreenshot(label:)` | Save a simulator screenshot |

### macOS App

| Step | Description |
|------|-------------|
| `launchMacApp(arguments:)` | Launch the macOS app |
| `terminateMacApp` | Terminate the macOS app |
| `macOpenSettings` | Open the Settings window |
| `macWaitForWindow(titled:timeout:)` | Wait for a window with the given title |
| `macSelectSettingsTab(_:)` | Click a Settings sidebar tab |
| `macClickButton(titled:)` | Click a button by title or `.help()` attribute |
| `macReadClipboard(storeAs:)` | Read clipboard contents into a variable |
| `macScreenshot(label:)` | Save a screenshot of the macOS app window |

### General

| Step | Description |
|------|-------------|
| `wait(seconds:)` | Sleep for a duration |
| `storeValue(key:value:)` | Store a literal value in the execution context |
| `log(_:)` | Log a message (supports `${variable}` interpolation) |

## Element queries (iOS)

The `ElementQuery` enum matches against the simulator's Accessibility tree:

| Query | Matches |
|-------|---------|
| `.label("exact text")` | Exact AXLabel match |
| `.labelContains("substring")` | AXLabel contains (case-insensitive) |
| `.role("AXButton")` | AXRole match |
| `.identifier("id")` | AXIdentifier match |
| `.roleAndLabelContains(role:label:)` | Both role and label substring |
| `.valueContains("text")` | AXValue contains |
| `.allOf([...])` | All sub-queries must match |

## Making UI elements discoverable

### iOS (Simulator AX tree)

Use standard SwiftUI accessibility modifiers. These map to AX attributes that `ElementQuery` can match:

```swift
Button { ... } label: { Image(systemName: "plus") }
    .accessibilityLabel("New Session")  // → ElementQuery.label("New Session")
```

### macOS (AppleScript/System Events)

SwiftUI buttons with `Label` don't expose a title in System Events. Use `.help()` which maps to the `AXHelp` attribute:

```swift
Button { ... } label: { Label("Generate Code", symbol: .key) }
    .help("Generate Pairing Code")  // discoverable by macClickButton
```

The `macClickButton(titled:)` step searches recursively by both `title` and `help` attributes.
