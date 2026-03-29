# Common E2E Scenario Patterns

Patterns extracted from existing scenarios in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/`.

## Pattern: Standard Setup (Server + Both Apps)

Most scenarios need the server running and both apps launched. The `FreshPairingScenario` handles this:

```swift
public static let scenario = ClaudeSpyE2ELib.scenario("My Scenario", tags: ["mytag"]) {
    // Reuse full pairing flow (includes server start, both app launches, pairing, verification)
    FreshPairingScenario.scenario

    // Now both apps are paired and connected; add scenario-specific steps
    TestStep.iosTap(.label("Some Button"))
}
```

### What FreshPairingScenario Provides

After embedding FreshPairingScenario, the state is:
- Server running on port 8765
- iOS app launched and paired
- macOS app launched and paired
- Both WebSocket connections verified (host + viewer)
- macOS Settings window open on "Remote Access" tab showing "Connected"

## Pattern: Clean State Start

Begin scenarios that don't compose on FreshPairingScenario with cleanup:

```swift
TestStep.uninstallIOSApp    // Remove previous iOS install
TestStep.terminateMacApp    // Kill previous macOS process

TestStep.startServer
TestStep.verifyServerHealth

TestStep.launchIOSApp
TestStep.launchMacApp
```

## Pattern: macOS-Only Scenario

For scenarios that don't need iOS or the relay server, tag with `"macos-only"` and use tmux directly. Use `Shortcut.macOnlySetup` to handle app launch and Panes window setup:

```swift
public static let scenario = ClaudeSpyE2ELib.scenario("My macOS Test", tags: ["macos-only"]) {
    TestStep.tmuxCreateSession(name: "test-session", width: 80, height: 24)

    Shortcut.macOnlySetup  // Launches app + opens Panes window (1000x600, sidebar 250)

    // Select a pane in the sidebar
    TestStep.macClickButton(titled: "test-session:0.0")
    TestStep.wait(seconds: 1)

    // Interact with terminal
    TestStep.macType(text: "echo hello", pressReturn: true)
}
```

If you need a different window size, override after the shortcut:
```swift
Shortcut.macOnlySetup
TestStep.macResizeWindow(width: 1_200, height: 700)
```

For scenarios that only need the Panes window (app already running), use `Shortcut.openPanesWindow(instance:)` instead.

Note: `launchMacApp` always includes `--server-url` to prevent accidental production connections, even without a running server.

## Pattern: Unpair Verification

After triggering unpair from either side, verify the full cleanup chain:

```swift
// Trigger unpair (various methods)
TestStep.macUnpair                    // Via test HTTP endpoint
// OR
TestStep.iosTap(.label("Delete"))     // Via iOS UI
TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))

// Verify cleanup
TestStep.waitForNoPairings(timeout: 15)           // Wait for server to process
TestStep.verifyServerHasPairings(count: 0)         // Assert count
TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 10)  // iOS returned to pairing view
```

## Pattern: iOS Swipe-to-Delete

Reveal and tap swipe actions on list rows:

```swift
// The row must have .accessibilityIdentifier("host-row") in SwiftUI
TestStep.iosSwipeLeft(.identifier("host-row"))
TestStep.wait(seconds: 1)
TestStep.iosTap(.label("Delete"))
TestStep.wait(seconds: 1)

// Handle confirmation dialog
TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))
```

## Pattern: Pairing Code Transfer

Transfer the pairing code from macOS clipboard to iOS:

```swift
// Generate and copy on macOS
TestStep.macOpenSettings
TestStep.macWaitForWindow(titled: "General", timeout: 5)
TestStep.macSelectSettingsTab("Remote Access")
TestStep.wait(seconds: 1)
TestStep.macClickButton(titled: "Generate Pairing Code")
TestStep.wait(seconds: 3)
TestStep.macClickButton(titled: "Copy Code")
TestStep.wait(seconds: 0.5)
TestStep.macReadClipboard(storeAs: "pairingCode")

// Enter on iOS
TestStep.wait(seconds: 1)
TestStep.iosType(text: "${pairingCode}")
TestStep.wait(seconds: 5)
```

## Pattern: Reconnection Testing

Test how apps handle server-side disconnections:

```swift
// Start with paired state
FreshPairingScenario.scenario

// Disconnect one side via server
TestStep.serverDisconnectDevice(.viewer)   // Disconnect iOS
// OR
TestStep.serverDisconnectDevice(.host)     // Disconnect macOS
TestStep.wait(seconds: 1)

// Take action while disconnected
TestStep.macUnpair
TestStep.wait(seconds: 2)

// Verify the disconnected side handles INVALID_PAIR on reconnect
TestStep.waitForNoPairings(timeout: 15)
TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 30)
```

## Pattern: Multi-Phase Assertion Testing

Use stored values to track state changes across phases:

```swift
// Phase 1: Record initial state
TestStep.tmuxStorePaneDimensions(target: "session:0.0", widthKey: "initialWidth", heightKey: "initialHeight")
TestStep.log("Initial: ${initialWidth}x${initialHeight}")

// Phase 2: Take action
TestStep.macResizeWindow(width: 1400, height: 900)
TestStep.macClickButton(titled: "Resize tmux pane to fit mirror view")
TestStep.wait(seconds: 1)

// Phase 3: Record and assert
TestStep.tmuxStorePaneDimensions(target: "session:0.0", widthKey: "newWidth", heightKey: "newHeight")
TestStep.log("After resize: ${newWidth}x${newHeight}")
TestStep.assertStoredNotEqual(key: "newWidth", otherKey: "initialWidth")
```

## Pattern: Screenshots

Screenshots are auto-numbered with a zero-padded counter (`01-`, `02-`, etc.) that resets per scenario run. Labels should be descriptive kebab-case without manual number prefixes. By default, screenshots compare against stored baselines; only use `compare: false` if there's very good reason to not compare. Comparing should be the default.

```swift
// Compared against baseline (default)
TestStep.iosScreenshot(label: "ios-pairing-view")
TestStep.macScreenshot(label: "mac-code-generated")

// With tolerance for anti-aliasing
TestStep.macScreenshot(label: "settings-window", tolerance: 1.0)
```

See `docs/e2e-testing.md` for baseline storage, diff images, and CLI options.


## Pattern: Run tmux Commands

Use `Shortcut.tmuxRunCommand` instead of the two-step `tmuxSendKeys` + Enter pattern:

```swift
// Instead of:
// TestStep.tmuxSendKeys(target: "my-session:0", keys: "echo hello", literal: true)
// TestStep.tmuxSendKeys(target: "my-session:0", keys: "Enter")

// Use:
Shortcut.tmuxRunCommand(target: "my-session:0", command: "echo hello")

// For non-literal commands (e.g., OSC escape sequences):
Shortcut.tmuxRunCommand(
    target: "my-session:0",
    command: "printf '\\033]2;My Title\\007'",
    literal: false
)
```

## Pattern: Connect iOS to Terminal Session

Use `Shortcut.iosConnectToSession` to navigate to a terminal pane on iOS:

```swift
// Instead of:
// TestStep.iosWaitForElement(.labelContains("my-session"), timeout: 15)
// TestStep.iosTap(.labelContains("my-session"))
// TestStep.wait(seconds: 3)
// TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
// TestStep.wait(seconds: 3)

// Use:
Shortcut.iosConnectToSession(sessionName: "my-session")
```

## Pattern: Clean Terminal for Rendering Tests

Use `Shortcut.tmuxClearAndSetPrompt` to set a plain prompt and clear the screen:

```swift
// Instead of:
// TestStep.tmuxSendKeys(target: "test:0", keys: #"export PS1='$ '"#, literal: true)
// TestStep.tmuxSendKeys(target: "test:0", keys: "Enter")
// TestStep.tmuxSendKeys(target: "test:0", keys: "clear", literal: true)
// TestStep.tmuxSendKeys(target: "test:0", keys: "Enter")
// TestStep.wait(seconds: 1)

// Use:
Shortcut.tmuxClearAndSetPrompt(target: "test:0")
```

## Pattern: Waiting for UI Transitions

After actions that trigger navigation or state changes, wait appropriately:

```swift
// After launching apps: 3 seconds for app initialization
TestStep.launchMacApp
TestStep.wait(seconds: 3)

// After button clicks: 0.5-1 second for UI response
TestStep.macClickButton(titled: "Some Button")
TestStep.wait(seconds: 1)

// After pairing code entry: 5 seconds for network + crypto handshake
TestStep.iosType(text: "${pairingCode}")
TestStep.wait(seconds: 5)

// For loading states: use waitForElementToDisappear instead of fixed waits
TestStep.iosWaitForElementToDisappear(.labelContains("Loading"), timeout: 15)

// For appearance: use waitForElement instead of fixed waits
TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
TestStep.macWaitForElement(titled: "Connected", timeout: 15)
```

Prefer `waitForElement`/`waitForElementToDisappear` over fixed `wait(seconds:)` when possible - they're more reliable and fail faster.
