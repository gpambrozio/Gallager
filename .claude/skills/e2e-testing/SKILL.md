---
name: e2e-testing
allowed-tools:
  - Bash(./scripts/e2e-test.sh *)
description: >
  This skill should be used when the user asks to "create an e2e test", "add an e2e scenario",
  "write an e2e test scenario", "update an e2e scenario", "modify an e2e test",
  "add a test step", "debug a failing e2e test", "add accessibility hooks for e2e",
  or mentions creating or editing end-to-end test scenarios for ClaudeSpy.
  It provides the scenario DSL, available test steps, element queries, and registration process.
---

# E2E Test Scenario Development

Guide for creating and updating end-to-end test scenarios for the ClaudeSpy distributed system (macOS app, iOS simulator app, in-process Vapor relay server).

## Architecture Overview

The E2E test framework lives in `ClaudeSpyPackage/Sources/`:
- **ClaudeSpyE2ELib/** - Test framework library (DSL, drivers, orchestrator, scenarios)
- **ClaudeSpyE2E/** - CLI entry point (`ClaudeSpyE2ECommand.swift` - scenario registration)

Scenarios are defined declaratively using a `@resultBuilder` DSL and executed sequentially by the `TestOrchestrator`.

## Creating a New Scenario

### Step 1: Create the Scenario File

Create a new Swift file in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/`.

Follow this exact pattern:

```swift
import Foundation

/// Brief description of what this scenario tests
public enum MyScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Human-Readable Name",
        tags: ["relevant-tag"]
    ) {
        // Test steps go here
        TestStep.startServer
        TestStep.verifyServerHealth
        TestStep.launchIOSApp
        // ...
    }
}
```

Key conventions:
- Use `public enum` (not struct/class) as a namespace
- The static property must be named `scenario`
- Use `ClaudeSpyE2ELib.scenario(...)` factory with the `@ScenarioBuilder` DSL
- Name should be human-readable (used in CLI `--scenario "Name"`)
- Tags categorize scenarios: `"smoke"`, `"pairing"`, `"unpair"`, `"reconnect"`, `"terminal"`, `"resize"`, `"macos-only"`, `"interactive"`

### Step 2: Register the Scenario

Add the scenario to the **end** of the `allScenarios` array in `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift`:

```swift
private static let allScenarios: [TestScenario] = [
    FreshPairingScenario.scenario,
    // ... existing scenarios ...
    MyScenario.scenario,  // Always add new scenarios at the end
]
```

**Important:** Always append at the end — never insert in the middle. The array position determines the numbered baseline directory prefix (e.g., `01-fresh-pairing/`, `02-new-terminal/`). Inserting in the middle shifts all subsequent numbers, breaking existing screenshot baselines.

### Step 3: Add Accessibility Hooks (if needed)

When a scenario interacts with new UI elements, ensure those elements are discoverable:

**iOS (SwiftUI):** Use standard accessibility modifiers.
```swift
Button { } label: { Image(systemName: "plus") }
    .accessibilityLabel("New Session")       // -> ElementQuery.label("New Session")
HStack { }
    .accessibilityIdentifier("host-row")     // -> ElementQuery.identifier("host-row")
```

**macOS (SwiftUI toolbar):** Use `.help()` for toolbar buttons (Label titles aren't exposed in System Events).
```swift
Button { } label: { Label("Generate Code", symbol: .key) }
    .help("Generate Pairing Code")           // -> macClickButton(titled:)
```

**macOS (sidebar rows):** Use `Button` (not `onTapGesture`) with `.accessibilityLabel()` on the Button itself.

### Step 4: Run the New Scenario and Verify It Passes

Before committing, always run the new scenario and confirm it passes:

```bash
./scripts/e2e-test.sh --scenario "Human-Readable Name"
```

If the scenario fails, fix the issue and re-run until it passes. **Never commit a failing e2e test.**

## Scenario Structure Rules

1. **Never include cleanup steps** - The orchestrator handles cleanup automatically (terminate apps, stop server, kill tmux)
2. **Start with clean state** - Begin scenarios with `uninstallIOSApp` + `terminateMacApp` if needed
3. **Always start server before apps** - Apps need the server URL for `--e2e-test` args
4. **Use composition** - Reuse existing scenarios by embedding them (steps get flattened inline)
5. **Add screenshots at key checkpoints** - Labels are auto-numbered (`01-`, `02-`, etc.) per scenario run; do not add manual number prefixes. Screenshots compare against baselines by default; pass `compare: false` for capture-only.
6. **Use `wait(seconds:)` after actions** - UI transitions need time; typical waits are 0.5-3 seconds
7. **Use numbered comments** - Group steps into logical phases with `// 1. Description` comments

## Composing Scenarios

Embed an existing scenario to reuse its steps:

```swift
public static let scenario = ClaudeSpyE2ELib.scenario("Advanced Test", tags: ["advanced"]) {
    FreshPairingScenario.scenario  // All pairing steps run first, inline

    // Additional steps with both apps paired and running
    TestStep.iosTap(.label("New Session"))
}
```

The `ScenarioBuilder` result builder flattens included scenario steps inline.

## Variable Interpolation

Pass data between steps via `ExecutionContext`:

```swift
TestStep.macReadClipboard(storeAs: "pairingCode")  // Store
TestStep.iosType(text: "${pairingCode}")            // Use
TestStep.log("Code was: ${pairingCode}")            // Use in logs

TestStep.storeValue(key: "expected", value: "80")   // Store literal
TestStep.tmuxStorePaneDimensions(target: "session:0.0", widthKey: "w", heightKey: "h")
TestStep.assertStoredEqual(key: "w", otherKey: "expected")
```

## Test Step Quick Reference

Steps are defined as `TestStep` enum cases. Full signatures and details are in `references/test-steps-reference.md`.

| Category | Key Steps |
|----------|-----------|
| **Server** | `startServer`, `verifyServerHealth`, `verifyServerHasPairings(count:)`, `waitForHostConnected`, `waitForViewerConnected`, `serverDisconnectDevice(_:)`, `waitForNoPairings` |
| **iOS** | `launchIOSApp`, `iosWaitForElement(_:timeout:)`, `iosTap(_:)`, `iosType(text:)`, `iosSwipeLeft(_:)`, `iosWaitForElementToDisappear(_:timeout:)`, `iosScreenshot(label:compare:tolerance:)`, `iosLogUI` |
| **macOS** | `launchMacApp`, `terminateMacApp`, `macOpenSettings`, `macWaitForWindow(titled:timeout:)`, `macSelectSettingsTab(_:)`, `macClickButton(titled:)`, `macClickMenuItem(menuButtonTitle:itemTitle:)`, `macUnpair`, `macReadClipboard(storeAs:)`, `macWaitForElement(titled:timeout:)`, `macOpenPanesWindow`, `macResizeWindow(width:height:)`, `macType(text:pressReturn:)`, `macScreenshot(label:compare:tolerance:)` |
| **Tmux** | `tmuxCreateSession(name:width:height:)`, `tmuxStorePaneDimensions(target:widthKey:heightKey:)` |
| **Assertions** | `assertStoredEqual(key:otherKey:)`, `assertStoredNotEqual(key:otherKey:)` |
| **General** | `wait(seconds:)`, `storeValue(key:value:)`, `log(_:)` |

## Element Queries (iOS)

The `ElementQuery` enum matches against the iOS accessibility tree. Full reference in `references/element-queries.md`.

| Query | Example |
|-------|---------|
| `.label("exact")` | `.label("New Session")` |
| `.labelContains("sub")` | `.labelContains("pairing code")` |
| `.identifier("id")` | `.identifier("host-row")` |
| `.role("Type")` | `.role("Button")` |
| `.roleAndLabelContains(role:label:)` | `.roleAndLabelContains(role: "Button", label: "Remove")` |
| `.valueContains("text")` | `.valueContains("Connected")` |
| `.allOf([...])` | `.allOf([.role("Button"), .labelContains("OK")])` |

Use `.roleAndLabelContains` for confirmation dialogs to target the button specifically (avoid matching dialog title text).

## Common Scenario Patterns

Detailed patterns are in `references/patterns.md`. Key patterns:

- **Full pairing flow** - Compose with `FreshPairingScenario.scenario`
- **macOS-only scenario** - Tag with `"macos-only"`, use `tmuxCreateSession` instead of server/iOS
- **Unpair verification** - Use `waitForNoPairings` + `verifyServerHasPairings(count: 0)`
- **Reconnection testing** - Use `serverDisconnectDevice(.viewer)` or `serverDisconnectDevice(.host)`
- **Assertion chains** - Store values with keys, then compare with `assertStoredEqual`/`assertStoredNotEqual`

## Debugging Tips

- Use `TestStep.iosLogUI` to dump the full iOS accessibility tree when element queries don't match
- Use `TestStep.log("message ${var}")` to trace variable values
- Add `TestStep.iosScreenshot(label:compare:tolerance:)` / `TestStep.macScreenshot(label:compare:tolerance:)` before failing steps
- Run specific scenario: `./scripts/e2e-test.sh --skip-build --scenario "Name"`
- Interactive mode to inspect state: `./scripts/e2e-test.sh --skip-build --interactive --scenario "Name"`

## Storage Isolation

Both apps accept `--e2e-test` which overrides `PreferencesService` and `SecretsService` with in-memory implementations. The macOS app also accepts `--tmux-socket <path>` for tmux session isolation. The orchestrator builds these launch arguments automatically.

## Additional Resources

### Reference Files

For detailed information, consult:
- **`references/test-steps-reference.md`** - Complete test step reference with all signatures, defaults, and usage notes
- **`references/element-queries.md`** - ElementQuery enum details, matching behavior, and best practices
- **`references/patterns.md`** - Common scenario patterns with full examples from the codebase
- **`docs/e2e-testing.md`** (project root) - Screenshot comparison workflow, baseline storage, auto-numbering, and CLI options

### Existing Scenarios (in `ClaudeSpyE2ELib/Scenarios/`)

Study these as reference implementations:
- **FreshPairingScenario** - Foundation scenario, most others compose on top of it
- **NewTerminalScenario** - Simple composition example
- **UnpairFromIOSScenario** - iOS swipe + confirmation dialog handling
- **UnpairFromMacOSScenario** - Unpair from macOS side, verify iOS cleanup
- **ResizePaneScenario** - macOS-only, tmux, assertions, multi-phase testing
- **DisconnectIOSUnpairMacOSScenario** - Disconnect iOS, unpair from macOS, INVALID_PAIR handling
- **DisconnectMacOSUnpairIOSScenario** - Disconnect macOS, unpair from iOS, INVALID_PAIR handling
- **LaunchAllScenario** - Simple launch without pairing (used for interactive mode)
