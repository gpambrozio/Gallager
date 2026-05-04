---
name: e2e-testing
allowed-tools:
  - Bash(./scripts/e2e-test.sh *)
description: Use this skill when writing, modifying, running, or debugging formal e2e test scenarios — the Swift DSL-based automated tests in ClaudeSpyE2ELib. This includes creating new scenario files, adding or changing TestStep sequences, fixing failing scenarios, choosing ElementQuery matchers, registering scenarios in allScenarios, adding accessibility identifiers/hooks for testability, running ./scripts/e2e-test.sh, updating screenshot baselines, or extending the test framework with new step types. Use this skill whenever someone mentions e2e scenarios, test steps, element queries, screenshot baselines, the ScenarioBuilder DSL, or wants to run the automated e2e suite. Do NOT use this skill for ad-hoc manual debugging, taking one-off screenshots, interactively driving the app, or exploratory testing without writing a formal scenario — use e2e-manual-debugging for those instead.
---

# E2E Test Scenario Development

Guide for creating and updating end-to-end test scenarios for the ClaudeSpy distributed system (macOS app, iOS simulator app, in-process Vapor relay server, optional second macOS instance for two-Mac pairing).

## Architecture Overview

The E2E test framework lives in `ClaudeSpyPackage/Sources/`:
- **ClaudeSpyE2ELib/** - Test framework library (DSL, drivers, orchestrator, scenarios, bundled scripts)
- **ClaudeSpyE2E/** - CLI entry point (`ClaudeSpyE2ECommand.swift` — scenario registration)

Scenarios are defined declaratively using a `@resultBuilder` DSL and executed sequentially by the `TestOrchestrator`.

## Running E2E scenarios

Always use `./scripts/e2e-test.sh` to run scenarios. It builds the apps, launches the orchestrator, and runs the scenario in a clean environment.

Common invocations:

```bash
# Build everything and run all scenarios
./scripts/e2e-test.sh

# Skip build, just run with previously built artifacts
./scripts/e2e-test.sh --skip-build

# Run a specific scenario by exact human-readable name
./scripts/e2e-test.sh --scenario "Fresh Pairing"

# List available scenarios
./scripts/e2e-test.sh --skip-build --list-scenarios

# Take screenshots but skip baseline comparison (one-off)
./scripts/e2e-test.sh --skip-build --no-compare --scenario "My Scenario"

# Interactive mode — runs scenario then waits for Enter so you can poke at the apps
./scripts/e2e-test.sh --skip-build --interactive --scenario "My Scenario"
```

Baselines are never auto-updated on a passing run; if your changes invalidate an existing baseline, delete the affected directory before re-running so the next pass regenerates it.

When a non-screenshot step fails (element missing, assertion failed, HTTP error), the orchestrator automatically captures a diagnostic screenshot of the running platform(s) — saved as `failure-step-NN-<target>.png` next to the scenario screenshots. Don't add manual diagnostic screenshots before each step.

## Creating a New Scenario

### Step 1: Create the Scenario File

Create a new Swift file in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/`. Follow this exact pattern:

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
        TestStep.launchIOSApp()
        // ...
    }
}
```

Key conventions:
- Use `public enum` (not struct/class) as a namespace
- The static property must be named `scenario`
- Use `ClaudeSpyE2ELib.scenario(...)` factory with the `@ScenarioBuilder` DSL
- Name should be human-readable (used in CLI `--scenario "Name"`)
- Tags categorize scenarios. Existing tags include `"smoke"`, `"pairing"`, `"unpair"`, `"reconnect"`, `"version-mismatch"`, `"terminal"`, `"rendering"`, `"resize"`, `"sessions"`, `"hooks"`, `"yolo"`, `"clipboard"`, `"file-browser"`, `"tabs"`, `"sidebar"`, `"layout"`, `"links"`, `"editor"`, `"project-search"`, `"keystroke"`, `"description"`, `"sync"`, `"persistence"`, `"disconnect"`, `"interactive"`, `"macos-only"`, `"ios"`, `"remote"`. Pick existing ones when they fit.

### Step 2: Register the Scenario

Add the scenario to the **end** of the `allScenarios` array in `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift`:

```swift
private static let allScenarios: [TestScenario] = [
    FreshPairingScenario.scenario,
    // ... existing scenarios ...
    MyScenario.scenario,  // Always add new scenarios at the end
]
```

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
    .help("Generate Pairing Code")           // -> macClickButton(titled:) AND ElementQuery.help("...")
```

**macOS (sidebar / List rows):** Use `Button` (not `onTapGesture`) with `.accessibilityLabel()` on the Button itself. For selection in `List`/`OutlineGroup` (where AXPress doesn't update selection state), use `macCGClick(titled:)` instead of `macClickButton`. For disclosure toggles and explicit buttons, `macClickButton` is fine.

### Step 4: Run the New Scenario and Verify It Passes

Before committing, always run the new scenario and confirm it passes:

```bash
./scripts/e2e-test.sh --scenario "Human-Readable Name"
```

If the scenario fails, fix the issue and re-run until it passes. **Never commit a failing e2e test.**

## Scenario Structure Rules

1. **Never include cleanup steps** — the orchestrator handles cleanup automatically (terminate apps, stop server, kill tmux, reset blocked devices, remove injected scripts).
2. **Start with clean state** — Begin scenarios with `uninstallIOSApp` + `terminateMacApp()` if you're not composing on a setup scenario.
3. **Always start server before apps** — Apps need the server URL for `--e2e-test` args.
4. **Use composition** — Reuse existing scenarios by embedding them; steps get flattened inline.
5. **Add screenshots at key checkpoints** — Labels are auto-numbered (`01-`, `02-`, …) per scenario run; do not add manual number prefixes. Screenshots compare against baselines by default — pass `compare: false` only for screens whose content varies between runs (live timestamps, animations in flight). Baseline comparison is the default and the strong preference.
6. **Screenshot naming convention** — Labels must always start with a platform prefix: `mac-`, `ios-`, `host-`, or `viewer-`.
   - `mac-` for `macScreenshot` in standard scenarios
   - `ios-` for `iosScreenshot` in standard scenarios
   - `host-` and `viewer-` for `macScreenshot` in two-Mac pairing scenarios (instance 0 = host, instance 1 = viewer)
7. **Never commit screenshot baselines** — Baselines in `E2ETests/` are generated by CI and must not be pushed to GitHub. If your changes cause existing baselines to become invalid (e.g., UI changes, new/reordered screenshots), delete the affected baseline directory (e.g., `rm -rf E2ETests/mark-handled/`) so CI regenerates them.
8. **Use `wait(seconds:)` after actions** — UI transitions need time; typical waits are 0.5–3 seconds. Prefer `*WaitForElement*`, `waitForTmuxDisplayMessage`, or `waitForFileContains` over fixed sleeps when an observable signal exists.
9. **Use numbered comments** — Group steps into logical phases with `// 1. Description` comments.

## Composing Scenarios

Embed an existing scenario to reuse its steps:

```swift
public static let scenario = ClaudeSpyE2ELib.scenario("Advanced Test", tags: ["advanced"]) {
    FreshPairingScenario.scenario  // All pairing steps run first, inline

    // Additional steps with both apps paired and running
    TestStep.iosTap(.label("New Session"))
}
```

The `ScenarioBuilder` result builder flattens included scenario steps inline. It also supports `if`/`else` and `for` loops, so scenarios can branch or fan out programmatically when needed.

### Reusable Shortcuts

The `Shortcut` enum in `ScenarioShortcuts.swift` provides pre-built scenario fragments for common setup sequences. **Always prefer shortcuts over duplicating setup steps.**

| Shortcut | What it provides |
|----------|-----------------|
| `Shortcut.macOnlySetup` | Launches macOS app + opens Panes window (positioned at 10,10, 1000×600, sidebar 250) |
| `Shortcut.openPanesWindow(instance:)` | Opens and sizes the Panes window for a given instance (expects app already running) |
| `Shortcut.twoMacPairing` | Starts server, launches host (instance 0) + viewer (instance 1), pairs them, verifies "Connected" |
| `Shortcut.addMacViewer` | After `FreshPairingScenario`, adds a Mac viewer as instance 1 |
| `Shortcut.tmuxRunCommand(target:command:literal:)` | Sends a command to a tmux pane and presses Enter (`literal` defaults to `true`) |
| `Shortcut.tmuxClearAndSetPrompt(target:)` | Sets a plain `$ ` prompt and clears the screen (for clean rendering tests) |
| `Shortcut.iosConnectToSession(sessionName:)` | Waits for an iOS session, taps it, waits for "Connecting" to disappear |
| `Shortcut.iosTapCommandsMenuItem(_:timeout:)` | Opens iOS toolbar Commands menu, taps an item, menu auto-dismisses |
| `Shortcut.iosVerifyCommandsMenuItem(_:timeout:)` | Opens Commands menu, verifies an item exists, dismisses by tapping outside |

Usage:
```swift
public static let scenario = ClaudeSpyE2ELib.scenario("My Test", tags: ["macos-only"]) {
    Shortcut.macOnlySetup  // Replaces manual launchMacApp + openPanesWindow steps

    // Test-specific steps...
    TestStep.macScreenshot(label: "mac-initial-state")
}
```

Override defaults after a shortcut if needed:
```swift
Shortcut.macOnlySetup
TestStep.macResizeWindow(width: 1_200, height: 700)  // Override default size
```

Every macOS step takes `instance: Int = 0` — use `instance: 1` for the second Mac in two-Mac scenarios (host=0, viewer=1). Ports, hook-server files, and tmux-socket-adjacent paths are derived from the instance automatically. Use `host-` / `viewer-` screenshot label prefixes instead of `mac-` so baselines are visually distinguishable. See `references/patterns.md` "Two-Mac Pairing" for the full pattern.

## Variable Interpolation

Pass data between steps via `ExecutionContext`. Steps that **store** a value: `storeValue`, `macReadClipboard`/`iosReadClipboard`, `tmuxStorePaneId`, `tmuxStorePaneDimensions`, `tmuxCapturePaneContent`, `tmuxStoreDisplayMessage`, `readFile`, `waitForFileContains`. Reference the stored value as `${key}` in any string argument (`iosType`, `macType`, `log`, `assertStoredContains` substrings, `macSendHookEvent` JSON, tmux targets, file paths). The orchestrator interpolates before passing to drivers.

## Test Steps

Steps are `TestStep` enum cases organised in 8 categories: **Server**, **iOS**, **macOS** (every macOS step accepts `instance: Int = 0`), **Tmux**, **Hooks** (`macSendHookEvent`), **Assertions** (`assertStoredEqual` / `NotEqual` / `Contains` / `NotContains`), **Scripts/Files** (`injectScript`, `readFile`, `waitForFileContains`), and **General** (`wait`, `storeValue`, `log`).

Read `references/test-steps-reference.md` before writing a step you haven't used before — it has every signature, default value, and per-step usage note (including subtle ones like `macCGClick` vs `macClickButton`, `serverDisconnectDevice` vs `serverBlockDevice`, and `macType`'s `charDelay` for remote terminals).

## Element Queries

The `ElementQuery` enum matches against accessibility trees on both iOS (XCUITest runner) and macOS (TestAccessibilityServer via `macWaitForElementQuery`). Full reference in `references/element-queries.md`.

| Query | Example |
|-------|---------|
| `.label("exact")` | `.label("New Session")` |
| `.labelContains("sub")` | `.labelContains("pairing code")` |
| `.identifier("id")` | `.identifier("host-row")` |
| `.role("Type")` | `.role("Button")` |
| `.roleAndLabelContains(role:label:)` | `.roleAndLabelContains(role: "Button", label: "Remove")` |
| `.valueContains("text")` | `.valueContains("Connected")` |
| `.help("text")` | `.help("Generate Pairing Code")` |
| `.anyTextMatches("text")` | `.anyTextMatches("Check the spelling")` |
| `.allOf([...])` | `.allOf([.help("Auto-resize..."), .valueContains("1")])` |

Use `.roleAndLabelContains` for confirmation dialogs to target the button specifically (avoid matching the dialog title text). Use `.help(...)` to target macOS toolbar buttons by their tooltip. Use `.anyTextMatches(...)` when the text could be exposed via `title`, `label`, `value`, or `help`.

## Common Scenario Patterns

Detailed patterns are in `references/patterns.md`. Key patterns:

- **Full pairing flow** — Compose with `FreshPairingScenario.scenario`
- **macOS-only scenario** — Tag with `"macos-only"`, use `Shortcut.macOnlySetup` or `tmuxCreateSession` instead of server/iOS
- **Two-Mac pairing** — Use `Shortcut.twoMacPairing` for host (0) + viewer (1) setup; drive each independently via `instance:`
- **Add viewer to existing pairing** — Use `Shortcut.addMacViewer` after `FreshPairingScenario`
- **Run commands in tmux** — Use `Shortcut.tmuxRunCommand(target:command:)` instead of manual sendKeys + Enter
- **Connect iOS to terminal** — Use `Shortcut.iosConnectToSession(sessionName:)` for the wait-tap-connect pattern
- **Drive iOS Commands menu** — Use `Shortcut.iosTapCommandsMenuItem` / `iosVerifyCommandsMenuItem`
- **Clean terminal for rendering** — Use `Shortcut.tmuxClearAndSetPrompt(target:)` for clean baselines
- **Hook events / Claude session lifecycle** — Use `tmuxStorePaneId` + `macSendHookEvent` to drive `SessionStart`, `Stop`, `PermissionRequest`, etc.
- **Terminal content assertions** — `tmuxCapturePaneContent` + `assertStoredContains` / `assertStoredNotContains` (more robust than pixel comparison for text-only checks)
- **Script injection** — `injectScript(name:)` copies a Python helper from `Scenarios/Scripts/` into `$TMPDIR` for use inside tmux commands; auto-cleaned
- **Unpair verification** — Use `waitForNoPairings` + `verifyServerHasPairings(count: 0)`
- **Reconnection testing** — `serverDisconnectDevice` for transient drops, `serverBlockDevice` + `serverUnblockDevice` for sustained outages
- **Version compatibility** — `launchIOSApp(appVersion:minRequiredPartnerVersion:)` / `launchMacApp(...)` to start mismatched, then `iosSetAppVersion`/`macSetAppVersion` with `nil` to simulate "the user updated the app"
- **Right-click / context menus** — `macContextMenuClick(elementTitle:menuItem:)`
- **List/sidebar selection** — `macCGClick(titled:)` for `List`/`OutlineGroup` rows; `macClickButton(titled:)` for explicit `Button` elements
- **Field interaction** — `macFocusElement` + `macSelectAll` + `macType` to replace text in a field; `macPressTab/Escape/Return/Space` for keyboard-only navigation
- **Assertion chains** — Store values with keys, then compare with `assertStoredEqual` / `assertStoredNotEqual` / `assertStoredContains` / `assertStoredNotContains`

## Debugging Tips

- Use `TestStep.iosLogUI` to dump the full iOS accessibility tree when element queries don't match
- Use `TestStep.log("message ${var}")` to trace variable values
- Run specific scenario: `./scripts/e2e-test.sh --skip-build --scenario "Name"`
- Interactive mode to inspect state: `./scripts/e2e-test.sh --skip-build --interactive --scenario "Name"`
- Skip baseline comparison while iterating: `./scripts/e2e-test.sh --skip-build --no-compare --scenario "Name"`
- **Stuck on "what label/identifier does this element actually expose?"** — use the `e2e-manual-debugging` skill. It boots an interactive e2e instance and walks through dumping the iOS view hierarchy / inspecting the macOS accessibility tree (Xcode Accessibility Inspector + AppleScript) so you can read the real attributes instead of guessing. Apply when `iosTap` / `iosWaitForElement` / `macClickButton` / `macWaitForElement` keeps timing out and you're not sure what to put in the query.
- Failure screenshots are auto-captured for any non-screenshot step failure (saved as `failure-step-NN-<target>.png`) — no need to add manual screenshots before suspect steps

## Storage Isolation

Both apps accept `--e2e-test` which overrides `PreferencesService` and `SecretsService` with in-memory implementations. The macOS app also accepts `--tmux-socket <path>` for tmux session isolation. The orchestrator builds these launch arguments automatically per instance, so the user's real Gallager config and tmux server are untouched.

## Additional Resources

### Reference Files

For detailed information, consult:
- **`references/test-steps-reference.md`** — Complete test step reference with all signatures, defaults, and usage notes (including the `instance:` parameter on every macOS step)
- **`references/element-queries.md`** — ElementQuery enum details, matching behavior, best practices (including `.help` and `.anyTextMatches`)
- **`references/patterns.md`** — Common scenario patterns with full examples (multi-instance, hooks, scripts, version mismatch, terminal content assertions, …)
- **`docs/e2e-testing.md`** (project root) — Screenshot comparison workflow, baseline storage, auto-numbering, failure screenshots, results-repo publishing, and CLI options

### Existing Scenarios (in `ClaudeSpyE2ELib/Scenarios/`)

Study these as reference implementations for specific patterns:
- **FreshPairingScenario** — Foundation scenario, most others compose on top of it
- **NewTerminalScenario** — Simple composition example
- **UnpairFromIOSScenario / UnpairFromMacOSScenario** — Unpair from each side, swipe + confirmation, INVALID_PAIR handling
- **ResizePaneScenario** — macOS-only, tmux dimensions, multi-phase assertion testing
- **DisconnectIOSUnpairMacOSScenario / DisconnectMacOSUnpairIOSScenario** — `serverDisconnectDevice` reconnection scenarios
- **HostDisconnectClearsSessionsScenario** — `serverBlockDevice` + `macSendHookEvent` + multi-instance viewer
- **VersionMismatchOldIOSViewerScenario** (and siblings) — Version compatibility with `iosSetAppVersion`/`macSetAppVersion`
- **AskUserQuestionScenario / ClaudeSession*Scenario / YoloMode*Scenario** — Hook-event-driven session lifecycle
- **ClipboardSyncScenario / ClipboardSyncMacViewerScenario** — `iosReadClipboard`/`macReadClipboard` + `assertStoredContains`
- **EmojiTableRenderingScenario / TruecolorRenderingScenario / FooterRenderingScenario** — `injectScript` for deterministic terminal output
- **FileBrowserScenario** — `macCGClick` for List selection, `macContextMenuClick`, `macSelectAll`
- **TwoMacPairingScenario / MultiPaneWindowScenario** — `Shortcut.twoMacPairing` and host/viewer instances
- **LaunchAllScenario** — Simple launch without pairing (used for interactive mode)
