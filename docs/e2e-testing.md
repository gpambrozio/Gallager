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
    │   └── Simulator/         # simctl, XCUITest runner HTTP client
    ├── Orchestrator/          # Step execution + cleanup
    │   ├── TestOrchestrator.swift
    │   └── ExecutionContext.swift  # Variable storage between steps
    ├── Scenarios/             # Test scenario definitions
    └── Utilities/             # ProcessRunner, Polling helpers

ClaudeSpyE2EHost/              # Minimal iOS app target (host for UITest bundle)
├── AppDelegate.swift
├── ViewController.swift
└── Info.plist

ClaudeSpyE2ERunner/            # UI Testing Bundle target
├── ClaudeSpyE2ERunnerTests.swift  # Entry point: starts HTTP server
├── Server/
│   ├── E2EHTTPServer.swift    # FlyingFox HTTP server (port 22087)
│   └── RouteHandlerFactory.swift
├── Handlers/                  # HTTP route handlers
│   ├── ViewHierarchyHandler.swift  # XCUIElement.snapshot() → JSON
│   ├── TouchHandler.swift     # Tap at coordinates
│   ├── SwipeHandler.swift     # Swipe gestures
│   ├── InputTextHandler.swift # Type text
│   ├── CustomActionHandler.swift  # Trigger named accessibility actions
│   ├── ScreenshotHandler.swift
│   └── StatusHandler.swift    # Health check
├── XCTest/                    # Private API wrappers
│   ├── EventRecord.swift      # XCSynthesizedEventRecord wrapper
│   ├── PointerEventPath.swift # XCPointerEventPath wrapper
│   ├── RunnerDaemonProxy.swift # XCTRunnerDaemonSession.daemonProxy
│   └── AXClientSwizzler.swift # Override maxDepth via swizzle
├── Models/
│   ├── AXElement.swift        # Parsed snapshot element (Codable)
│   └── RequestModels.swift
└── Helpers/
    ├── RunningApp.swift       # Find foreground app
    └── ScreenSizeHelper.swift
```

### How it works

1. **ClaudeSpyE2ECommand** parses CLI args and creates a `TestOrchestrator`
2. **TestOrchestrator** runs scenarios sequentially, executing each `TestStep` via the appropriate driver
3. **Drivers** handle platform interaction:
   - **SimulatorDriver** — boots simulator, installs/launches apps, manages XCUITest runner lifecycle, communicates with it via HTTP for UI inspection, taps, swipes, and text input
   - **MacOSDriver** — launches macOS app, clicks buttons via AppleScript (`osascript`), takes screenshots
   - **ServerDriver** — starts/stops an in-process Vapor server, checks health and pairing state
4. After each scenario, the orchestrator runs **cleanup** (stop XCUITest runner, terminate both apps, stop server) regardless of pass/fail

### XCUITest runner

iOS UI automation uses a separate **XCUITest runner** process running in the Simulator. This replaces the previous in-app accessibility server approach.

The runner is a UI Testing bundle (`ClaudeSpyE2ERunner`) hosted by a minimal app (`ClaudeSpyE2EHost`). It exposes an HTTP server on port 22087 with endpoints for:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/status` | GET | Health check |
| `/viewHierarchy` | POST | Full UI tree via `XCUIElement.snapshot().dictionaryRepresentation` |
| `/touch` | POST | Tap at (x,y) via synthesized touch events |
| `/swipe` | POST | Swipe gesture via synthesized touch events |
| `/inputText` | POST | Type text via daemon proxy |
| `/customAction` | POST | Trigger named accessibility action on an element |
| `/screenshot` | POST | Capture screenshot |

The runner uses XCTest private APIs (`XCSynthesizedEventRecord`, `XCPointerEventPath`, `XCTRunnerDaemonSession`) for touch synthesis and `XCUIElement.snapshot()` for privileged, complete view hierarchy access. This gives it visibility into confirmation dialogs, system alerts, and other UI elements that an in-app server cannot see.

The `SimulatorDriver` manages the runner lifecycle:
1. Installs the host app via `xcrun simctl install`
2. Starts the runner via `xcodebuild test-without-building`
3. Polls `/status` until responsive
4. Sends the target app's `bundleId` in requests so the runner inspects the correct app
5. Kills the runner process on cleanup

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

# Run a specific scenario
./scripts/e2e-test.sh --scenario "Fresh Pairing"
./scripts/e2e-test.sh --skip-build --scenario "Unpair from iOS"

# Run with a specific simulator
./scripts/e2e-test.sh --sim-name "iPhone 16 Pro"

# Other options
./scripts/e2e-test.sh --screenshots /path/to/dir

# Interactive mode: launch all apps and wait (no pairing)
./scripts/e2e-test.sh --skip-build --interactive

# Interactive mode: run a scenario then wait
./scripts/e2e-test.sh --skip-build --interactive --scenario "Fresh Pairing"

# List available scenarios
./scripts/e2e-test.sh --skip-build --list-scenarios

# Custom tmux socket path
./scripts/e2e-test.sh --tmux-socket /tmp/my-test.sock
```

The script builds four targets: ClaudeSpyServer (macOS), ClaudeSpy (iOS), ClaudeSpyE2EHost (build-for-testing), and ClaudeSpyE2E (CLI coordinator).

### Running manually

Build all targets first, then:

```bash
ClaudeSpyE2E \
    --ios-app-path /path/to/Gallager.app \
    --macos-app-path /path/to/Gallager.app \
    --sim-name "iPhone 17 Pro" \
    --screenshots-dir /tmp/e2e-screenshots \
    --baselines-dir ./E2ETests \
    --tmux-socket /tmp/claudespy-e2e.sock \
    --e2e-runner-path /path/to/derived-data
```

The `--e2e-runner-path` points to the derived data directory from `xcodebuild build-for-testing` of the `ClaudeSpyE2EHost` scheme. It contains the `.xctestrun` file and host app needed to start the XCUITest runner.

### Running a specific scenario

```bash
./scripts/e2e-test.sh --scenario "Fresh Pairing"

# Or manually:
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
        TestStep.startServer
        TestStep.verifyServerHealth

        TestStep.launchIOSApp
        TestStep.iosWaitForElement(.labelContains("some text"), timeout: 10)
        TestStep.iosScreenshot(label: "my-screenshot")

        TestStep.launchMacApp
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-screenshot")
    }
}
```

The orchestrator builds launch arguments automatically:
- `startServer` uses a fixed port (8765)
- `launchIOSApp` passes `--e2e-test --server-url ws://127.0.0.1:8765`
- `launchMacApp` passes `--e2e-test --server-url ws://127.0.0.1:8765 --tmux-socket <path>`

The server URL is always included (even for macOS-only scenarios without a running server) to prevent accidental connection to production.

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
| `startServer` | Start the in-process Vapor relay server (fixed port 8765) |
| `verifyServerHealth` | Wait for the server health endpoint to respond |
| `verifyServerHasPairings(count:)` | Assert the number of active pairings |
| `waitForHostConnected(timeout:)` | Wait for the macOS host to connect via WebSocket |
| `waitForViewerConnected(timeout:)` | Wait for the iOS viewer to connect via WebSocket |
| `waitForNoPairings(timeout:)` | Wait until the server has no active pairings |
| `serverDisconnectDevice(_:)` | Disconnect a device's (`.host` or `.viewer`) WebSocket connections |
| `stopServer` | Stop the server and clean up `pairs.json` |

### iOS Simulator

| Step | Description |
|------|-------------|
| `launchIOSApp` | Boot simulator, install, launch iOS app, and start XCUITest runner |
| `terminateIOSApp` | Terminate the running iOS app |
| `uninstallIOSApp` | Terminate and uninstall the iOS app |
| `iosWaitForElement(_:timeout:)` | Wait for a UI element matching an `ElementQuery` |
| `iosWaitForElementToDisappear(_:timeout:)` | Wait for a UI element to disappear |
| `iosTap(_:)` | Wait for and tap a UI element |
| `iosTapCoordinate(x:y:)` | Tap at raw iOS point coordinates |
| `iosType(text:)` | Type text (supports `${variable}` interpolation) |
| `iosSwipeLeft(_:)` | Swipe left on a UI element (via XCUITest runner touch synthesis) |
| `iosScreenshot(label:compare:tolerance:)` | Take a screenshot; compares against baseline by default (see [Screenshot Comparison](#screenshot-comparison)). Pass `compare: false` to skip comparison. |
| `iosLogUI` | Dump the full iOS accessibility tree to the log (for debugging) |

### macOS App

| Step | Description |
|------|-------------|
| `launchMacApp` | Launch the macOS app (args built by orchestrator) |
| `terminateMacApp` | Terminate the macOS app |
| `macOpenSettings` | Open the Settings window |
| `macOpenPanesWindow` | Open the Panes window |
| `macWaitForWindow(titled:timeout:)` | Wait for a window with the given title |
| `macSelectSettingsTab(_:)` | Click a Settings sidebar tab |
| `macClickButton(titled:)` | Click a button/element by title, label, or `.help()` attribute |
| `macClickMenuItem(menuButtonTitle:itemTitle:)` | Click a menu trigger button then click a menu item |
| `macUnpair` | Trigger unpair on the first paired viewer via test HTTP endpoint |
| `macWaitForElement(titled:timeout:)` | Wait for a text element to appear in the macOS app's accessibility tree |
| `macReadClipboard(storeAs:)` | Read clipboard contents into a variable |
| `macResizeWindow(width:height:)` | Resize the app's frontmost window |
| `macType(text:pressReturn:)` | Type text via AppleScript keystroke (supports `${variable}` interpolation) |
| `macScreenshot(label:compare:tolerance:)` | Take a screenshot; compares against baseline by default (see [Screenshot Comparison](#screenshot-comparison)). Pass `compare: false` to skip comparison. |

### Tmux

| Step | Description |
|------|-------------|
| `tmuxCreateSession(name:width:height:)` | Create a tmux session on the test socket |
| `tmuxStorePaneDimensions(target:widthKey:heightKey:)` | Store pane dimensions in context variables |

### Assertions

| Step | Description |
|------|-------------|
| `assertStoredEqual(key:otherKey:)` | Assert two stored context values are equal |
| `assertStoredNotEqual(key:otherKey:)` | Assert two stored context values differ |

### General

| Step | Description |
|------|-------------|
| `wait(seconds:)` | Sleep for a duration |
| `storeValue(key:value:)` | Store a literal value in the execution context |
| `log(_:)` | Log a message (supports `${variable}` interpolation) |

## Element queries (iOS)

The `ElementQuery` enum matches against the iOS accessibility tree (provided by the XCUITest runner):

| Query | Matches |
|-------|---------|
| `.label("exact text")` | Exact label match |
| `.labelContains("substring")` | Label contains (case-insensitive) |
| `.role("Button")` | Role match (e.g., Button, StaticText, TextField) |
| `.identifier("id")` | Accessibility identifier match |
| `.roleAndLabelContains(role:label:)` | Both role and label substring |
| `.valueContains("text")` | Value contains |
| `.allOf([...])` | All sub-queries must match |

Role values use XCUIElement.ElementType names: Button, StaticText, TextField, Image, Window, Alert, etc.

## Making UI elements discoverable

### iOS (XCUITest runner)

Use standard SwiftUI accessibility modifiers. These map to attributes the XCUITest runner exposes via `snapshot().dictionaryRepresentation`:

```swift
Button { ... } label: { Image(systemName: "plus") }
    .accessibilityLabel("New Session")  // → ElementQuery.label("New Session")

HStack { ... }
    .accessibilityIdentifier("host-row")  // → ElementQuery.identifier("host-row")
```

For confirmation dialogs, use `roleAndLabelContains` to target buttons specifically and avoid matching dialog titles or message text:

```swift
// Dialog title: "Remove Pairing"
// Button label: "Remove MacBook Pro"
TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))
```

### macOS (TestAccessibilityServer)

The macOS app runs an in-process HTTP server (`TestAccessibilityServer` on port 18081) when launched with `--e2e-test`. The `macClickButton(titled:)` step queries this server, which searches for elements using multiple strategies:

1. **Toolbar items** — matches by `label`
2. **Sidebar/outline rows** — walks the NSView hierarchy to find `NSOutlineView` rows, then calls `accessibilityPerformPress()` on the `AXButton` inside
3. **Accessibility tree** — recursive walk via `accessibilityChildren()`, matching by `title`, `label`, `value`, or `help`

#### Toolbar buttons

SwiftUI buttons with `Label` don't expose a title in System Events. Use `.help()` which maps to the `AXHelp` attribute:

```swift
Button { ... } label: { Label("Generate Code", symbol: .key) }
    .help("Generate Pairing Code")  // discoverable by macClickButton
```

#### Sidebar rows (List items)

Sidebar rows in `List` must use `Button` (not `onTapGesture`) to be discoverable. Place `.accessibilityLabel()` on the `Button`, not on the row content — otherwise the label gets duplicated in the accessibility tree:

```swift
// Good: Button with accessibilityLabel on the button itself
Button {
    selectedPane = pane
} label: {
    PaneSidebarRow(pane: pane)
}
.buttonStyle(.plain)
.accessibilityLabel(pane.target)  // → macClickButton(titled: "session:0.0")

// Bad: onTapGesture — no AXPress action, clicks are unreliable
PaneSidebarRow(pane: pane)
    .onTapGesture { selectedPane = pane }
```

**Why Button matters:** `NSOutlineView` doesn't expose its rows through `accessibilityChildren()`, so the generic accessibility tree walker can't find them. The test server walks the NSView hierarchy instead, locates the matching row, then finds the `AXButton` inside it and calls `accessibilityPerformPress()`. Without a `Button`, there's no `AXPress` action to invoke.

## Screenshot comparison

The `iosScreenshot` and `macScreenshot` steps compare against stored baselines by default (`compare: true`). Pass `compare: false` to take a screenshot without comparison.

Screenshots are automatically numbered with a zero-padded counter (`01-`, `02-`, etc.) that resets per scenario — labels in scenarios should not include manual number prefixes.

### How it works

1. A screenshot is taken and auto-numbered (e.g. label `"home-screen"` becomes `01-home-screen.png`)
2. If no baseline exists for this label + scenario, the screenshot is saved as the new baseline and the step passes
3. If a baseline exists, a pixel-by-pixel comparison is performed
4. If the percentage of differing pixels exceeds the tolerance, the step fails and a diff image is generated

### Baseline storage

Baselines are stored under the `--baselines-dir` directory (default: `E2ETests`, relative to the project root), organized by scenario:

```
E2ETests/
├── 01-fresh-pairing/
│   ├── 01-ios-pairing-view.png       # baseline
│   ├── 01-ios-pairing-view_diff.png  # generated on failure
│   └── 02-mac-code-generated.png
└── 02-new-terminal/
    └── 01-new-session.png
```

Scenario names are sanitized to lowercase with spaces replaced by hyphens.

### Usage in scenarios

```swift
public enum MyScenario {
    public static let scenario = scenario("My Scenario") {
        // ... setup steps ...

        // Exact pixel match (tolerance: 0%, compare: true — both defaults)
        TestStep.iosScreenshot(label: "home-screen")

        // Allow up to 1% pixel difference (for anti-aliasing, animations, etc.)
        TestStep.macScreenshot(label: "settings-window", tolerance: 1.0)

        // Screenshot without comparison
        TestStep.iosScreenshot(label: "debug-state", compare: false)
    }
}
```

### First run (creating baselines)

On the first run, no baselines exist. Each comparison step will:
- Save the current screenshot as the baseline
- Log "Baseline created for '...'"
- Pass (no comparison to fail against)

Subsequent runs compare against these stored baselines.

### Updating baselines

To update baselines after intentional UI changes, delete the relevant baseline files:

```bash
# Delete all baselines for a scenario
rm -rf E2ETests/01-fresh-pairing/

# Delete a specific baseline
rm E2ETests/01-fresh-pairing/01-ios-pairing-view.png

# Delete all baselines
rm -rf E2ETests/
```

The next run will regenerate them.

### Diff images

When a comparison fails, a diff image is saved alongside the baseline with a `_diff` suffix. Differing pixels are highlighted in red; matching pixels are dimmed. The diff path is included in the error message.

### CLI option

```bash
ClaudeSpyE2E --baselines-dir /path/to/baselines ...
```

## Test report generation

The `e2e-report.sh` script runs all E2E scenarios, collects results and screenshots, and publishes a report to the [ClaudeSpyTestResults](https://github.com/gpambrozio/ClaudeSpyTestResults) repository.

### How it works

1. Gathers git metadata (branch, commit, PR number) from the current ClaudeSpy checkout
2. Clones or updates the results repository as a sibling folder (`../ClaudeSpyTestResults`)
3. Runs `e2e-test.sh` with `--json-output` to get structured step-level results
4. Copies screenshots into a **content-addressable image store** (`images/<sha256>.png`) — identical images are stored once
5. Generates a `report.json` with metadata and per-scenario/per-step results (including screenshot hashes)
6. Updates `results/index.json` with a summary of all runs (most recent first)
7. Commits and pushes everything to the results repository

### Usage

```bash
# Run all e2e tests and publish report
./scripts/e2e-report.sh

# Skip build (reuse previously built artifacts)
./scripts/e2e-report.sh --skip-build

# Run a specific scenario
./scripts/e2e-report.sh --scenario "Fresh Pairing"

# Custom results repo URL or local path
./scripts/e2e-report.sh --results-repo git@github.com:user/MyResults.git
./scripts/e2e-report.sh --results-dir /path/to/local/results
```

All `e2e-test.sh` options (`--skip-build`, `--sim-name`, `--scenario`, etc.) are passed through.

### Results repository structure

The results repository ([ClaudeSpyTestResults](https://github.com/gpambrozio/ClaudeSpyTestResults)) is a separate git repository that stores test results and screenshots. It includes a static HTML viewer that loads results dynamically from JSON — no server-side processing or rebuild needed.

```
ClaudeSpyTestResults/
├── index.html                        # Single-page viewer app
├── serve.sh                          # Local HTTP server for viewing
├── images/                           # Content-addressable image store
│   ├── <sha256>.png                  # Deduplicated screenshots
│   └── ...
└── results/
    ├── index.json                    # All runs (most recent first)
    ├── 2026-02-15_14-30-00_main/
    │   ├── report.json               # Metadata + scenario results
    │   └── results.json              # Raw step-level output
    └── 2026-02-14_10-00-00_feature-branch/
        ├── report.json
        └── results.json
```

Each `report.json` contains:
- **metadata** — branch, commit, commit message, PR number/URL, timestamp
- **scenarios** — array of scenario results, each with steps that include screenshot hashes (`imageHash`, `baselineHash`, `diffHash`), pass/fail status, and diff percentages

### Viewing results

```bash
cd ../ClaudeSpyTestResults && ./serve.sh
# Open http://localhost:8000
```

The viewer shows a list of runs with pass/fail status and lets you drill into individual scenarios and screenshot comparisons.
