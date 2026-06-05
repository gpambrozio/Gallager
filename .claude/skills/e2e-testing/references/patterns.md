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
TestStep.terminateMacApp()  // Kill previous macOS process

TestStep.startServer
TestStep.verifyServerHealth

TestStep.launchIOSApp()
TestStep.launchMacApp()
```

`launchMacApp` and `terminateMacApp` take an `instance:` parameter that defaults to `0`; the parens are required because of the default.

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

For scenarios that only need the Panes window (app already running), use `Shortcut.openPanesWindow(instance:)` instead. Note `openPanesWindow` is a function that takes an instance parameter.

`launchMacApp` always includes `--server-url` to prevent accidental production connections, even without a running server.

## Pattern: Two-Mac Pairing (host + viewer instances)

Every macOS step accepts an `instance:` parameter. Instance `0` is the primary app; `1+` are additional instances. Use `Shortcut.twoMacPairing` to get both up and paired, then drive them independently:

```swift
public static let scenario = ClaudeSpyE2ELib.scenario("My Two-Mac Test", tags: ["pairing"]) {
    Shortcut.twoMacPairing
    Shortcut.openPanesWindow()           // host (instance 0)
    Shortcut.openPanesWindow(instance: 1) // viewer

    TestStep.tmuxCreateSession(name: "shared", width: 80, height: 24)

    // Drive host and viewer independently
    TestStep.macClickButton(titled: "shared:0.0", instance: 0)  // host
    TestStep.macActivate(instance: 1)                           // viewer to front
    TestStep.macWaitForElement(titled: "shared", timeout: 15, instance: 1)
}
```

To extend a paired iOS+host scenario with a Mac viewer, use `Shortcut.addMacViewer` after `FreshPairingScenario`. Use the `host-`/`viewer-` screenshot label prefixes to distinguish the two Macs in baselines.

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
TestStep.macOpenSettings()
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

## Pattern: Reconnection / Disconnection Testing

Two server-side primitives drive disconnection scenarios:

- `serverDisconnectDevice(.host | .viewer)` — drops existing WebSockets but **allows immediate reconnection**. Use for transient drops.
- `serverBlockDevice(.host | .viewer)` — drops *and* blocks new connections until `serverUnblockDevice`. Use to simulate a sustained outage where the device must not silently reconnect during the assertion window.

```swift
// Sustained host outage: viewer should clear sessions
FreshPairingScenario.scenario
Shortcut.addMacViewer
// ... seed a session via macSendHookEvent ...

TestStep.serverBlockDevice(.host)
TestStep.wait(seconds: 5)

TestStep.iosWaitForElementToDisappear(.labelContains("MyProject"), timeout: 15)
TestStep.macWaitForElementToDisappear(titled: "shared-session", timeout: 15, instance: 1)
```

Or transient drop + INVALID_PAIR-on-reconnect:

```swift
TestStep.serverDisconnectDevice(.viewer)
TestStep.wait(seconds: 1)
TestStep.macUnpair                                 // unpair while iOS is offline
TestStep.waitForNoPairings(timeout: 15)
TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 30)
```

## Pattern: Version Compatibility

Simulate an old or mismatched app build using `appVersion` / `minRequiredPartnerVersion` overrides on launch, then "upgrade" at runtime via `iosSetAppVersion` / `macSetAppVersion`:

```swift
TestStep.startServer
TestStep.verifyServerHealth

// Mac host on default version, iOS viewer pretending to be an old build
TestStep.launchMacApp()
TestStep.launchIOSApp(appVersion: "0.1", minRequiredPartnerVersion: "0.0")

// ... pair them; mismatch surfaces in peerHello, not pairing ...

TestStep.macWaitForElement(titled: "running version 0.1", timeout: 20)
TestStep.iosWaitForElement(.identifier("host-version-mismatch-row"), timeout: 15)

// Simulate "user updates the app" — clear overrides at runtime
TestStep.iosSetAppVersion(appVersion: nil, minRequiredPartnerVersion: nil)
TestStep.macSetAppVersion(appVersion: nil, minRequiredPartnerVersion: nil)
TestStep.iosTap(.identifier("host-version-mismatch-row"))
TestStep.iosTap(.label("Retry"))
TestStep.macWaitForElement(titled: "Viewer connected", timeout: 20)
```

Tag with `"version-mismatch"`. The relay server never sees version info — enforcement is peer-to-peer in the encrypted `peerHello` exchange.

## Pattern: Hook Events (Driving Claude Session Lifecycle)

`macSendHookEvent` POSTs to the macOS app's real `/api/hooks` endpoint, letting scenarios drive Claude session state without invoking real Claude. Pair it with `tmuxStorePaneId` so the event addresses the right pane:

```swift
TestStep.tmuxCreateSession(name: "work", width: 80, height: 24)
TestStep.tmuxStorePaneId(target: "work:0.0", storeAs: "paneId")

TestStep.macSendHookEvent(
    json: """
    {
        "hook_event_name": "SessionStart",
        "session_id": "e2e-session",
        "timestamp": "2026-04-06T10:00:00.000000Z"
    }
    """,
    tmuxPane: "${paneId}",
    projectPath: "/Users/test/MyProject"
)
TestStep.wait(seconds: 3)

// Now assert on UI: iOS sessions list, mac sidebar, etc.
TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 15)
```

Other supported event types include `Stop`, `Notification`, `PermissionRequest`, `PermissionDenied`, and `UserPromptSubmit` — useful for testing yolo-mode auto-approve, ask-user-question, mark-handled, and similar Claude-session flows.

## Pattern: Script Injection for Terminal Rendering Tests

For scenarios that need deterministic terminal output (tables, emojis, true-color, kitty keyboard probes), put a Python helper in `ClaudeSpyE2ELib/Scenarios/Scripts/` and inject it:

```swift
TestStep.injectScript(name: "emoji_tables.py")

// Run it inside the tmux pane
Shortcut.tmuxRunCommand(target: "render-test:0", command: "python3 $TMPDIR/emoji_tables.py")
TestStep.wait(seconds: 2)

TestStep.macScreenshot(label: "mac-emoji-tables-rendered")
```

The script is auto-cleaned when the scenario ends. Bundle additions are picked up automatically as SPM resources.

## Pattern: Terminal Content Assertions (No Screenshot)

When you only care that the terminal contains specific text — not the exact pixels — capture the pane content and assert on it. This is more robust than a pixel comparison and gives a readable failure message:

```swift
Shortcut.tmuxRunCommand(target: "test:0", command: "echo HELLO")
TestStep.wait(seconds: 1)

TestStep.tmuxCapturePaneContent(target: "test:0", storeAs: "paneText")
TestStep.assertStoredContains(key: "paneText", substring: "HELLO")
TestStep.assertStoredNotContains(key: "paneText", substring: "ERROR")
```

The same pattern works for clipboard sync (read with `iosReadClipboard` / `macReadClipboard`, assert with `assertStoredContains`) and for files written by the app (`readFile` / `waitForFileContains` + `assertStoredContains`).

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

Screenshots are auto-numbered with a zero-padded counter (`01-`, `02-`, etc.) that resets per scenario run. Labels should be descriptive kebab-case **starting with a platform prefix** (`ios-`, `mac-`, `host-`, `viewer-`) and without manual number prefixes. By default, screenshots compare against stored baselines; only use `compare: false` when content varies between runs (e.g. live timestamps, animations in flight) — and treat that as the exception, not the default.

```swift
// Compared against baseline (default)
TestStep.iosScreenshot(label: "ios-pairing-view")
TestStep.macScreenshot(label: "mac-code-generated")

// With higher tolerance for screens whose iOS state is non-deterministic
TestStep.macScreenshot(label: "mac-host-and-viewer", tolerance: 5)

// Per-instance screenshot (host vs viewer)
TestStep.macScreenshot(label: "host-sidebar", instance: 0)
TestStep.macScreenshot(label: "viewer-sidebar", instance: 1)
```

iOS defaults: `tolerance: 0.5`, `perPixelThreshold: 0.3`.
macOS defaults: `tolerance: 2`, `perPixelThreshold: 0.02` (looser to absorb color-space normalisation noise).

When a non-screenshot step fails (element missing, assertion failed, HTTP error), the orchestrator automatically captures diagnostic screenshots of the running platforms — saved as `failure-step-NN-<target>.png` next to the scenario screenshots. You don't need to add manual diagnostic screenshots before each step.

See `docs/e2e-testing.md` for baseline storage, diff images, and CLI options.

## Pattern: Right-Click and Context Menus

Use `macContextMenuClick` for the combined right-click + menu-item-pick:

```swift
TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Copy Path")
TestStep.wait(seconds: 1)
TestStep.macReadClipboard(storeAs: "copiedPath")
TestStep.assertStoredContains(key: "copiedPath", substring: "/hello.txt")
```

Or split it when you need to inspect the menu before clicking:

```swift
TestStep.macRightClick(titled: "hello.txt")
TestStep.macWaitForElement(titled: "Copy Relative Path", timeout: 2)
TestStep.macClickButton(titled: "Open in New Tab")
```

## Pattern: List/Sidebar Selection (CGClick vs ClickButton)

SwiftUI `List`/`OutlineGroup` row selection often doesn't fire from `accessibilityPerformPress`. Use:

- `macCGClick(titled: ...)` — synthesised mouse click. Use for selecting list/outline rows that need a real click to update `selection` state.
- `macClickButton(titled: ...)` — AXPress fallback. Use for buttons, disclosure toggles, toolbar items, and sidebar rows backed by an explicit `Button { ... } label: { ... }`.

When in doubt, try `macClickButton` first; if selection state doesn't update, switch to `macCGClick`.

## Pattern: Keyboard / Field Interaction on macOS

To replace the contents of a text field:

```swift
TestStep.macFocusElement(titled: "Pairing Code")
TestStep.wait(seconds: 0.5)
TestStep.macSelectAll                  // Cmd+A on the focused field
TestStep.macType(text: "${newCode}", pressReturn: true)
```

Keyboard primitives also include `macPressTab` / `macPressEscape` / `macPressReturn` / `macPressSpace` for dialog driving without a button title.

When typing into a *remote* terminal (viewer side of a pairing), use `charDelay` so each keystroke has time to round-trip:

```swift
TestStep.macType(text: "echo hi\n", charDelay: 0.05, instance: 1)
```

## Pattern: Reusable Shortcuts

Always prefer existing shortcuts over duplicating setup steps. Current shortcuts (`Shortcut.*`):

- `macOnlySetup` — launch macOS app + open Panes window (1000×600, sidebar 250).
- `openPanesWindow(instance:)` — open and size the Panes window for a given instance.
- `twoMacPairing` — server up, host (instance 0) and viewer (instance 1) launched and paired.
- `addMacViewer` — after `FreshPairingScenario`, adds a Mac viewer as instance 1.
- `tmuxRunCommand(target:command:literal:)` — send command + Enter (defaults to literal text).
- `tmuxClearAndSetPrompt(target:)` — set plain `$ ` prompt and clear screen.
- `iosConnectToSession(sessionName:)` — wait for session row, tap it, wait for "Connecting" to disappear.
- `iosTapCommandsMenuItem(_:timeout:)` — open iOS toolbar Commands menu, tap an item, menu auto-dismisses.
- `iosVerifyCommandsMenuItem(_:timeout:)` — same as above but only verifies the item exists, then dismisses by tapping outside.

```swift
// Toggle a yolo-mode-style command from iOS
Shortcut.iosTapCommandsMenuItem("Enable Yolo Mode")

// Verify a command appears without invoking it
Shortcut.iosVerifyCommandsMenuItem("Disable Yolo Mode", timeout: 10)
```

## Pattern: Waiting for UI Transitions

**The single biggest reason scenarios run slowly is unnecessary fixed `wait(seconds:)` steps.** Every wait pays its full duration whether the UI needed it or not, and these waits compound across 80+ scenarios. The fix is straightforward: prefer state-driven waits whenever an observable signal exists.

### Rule: never put a fixed `wait` directly before a `*WaitFor*` step

The `*WaitFor*` steps (`iosWaitForElement`, `iosWaitForElementToDisappear`, `macWaitForElement`, `macWaitForElementQuery`, `macWaitForWindow`, `macAssertWindowTitle`, `waitForHostConnected`, `waitForViewerConnected`, `waitForNoPairings`, `verifyServerHasPairings`, `waitForTmuxDisplayMessage*`, `waitForFileContains`) all poll until either the condition is satisfied or the timeout expires. A fixed `wait` immediately before one of them adds nothing — the poll would have run for that duration anyway — so just delete it:

```swift
// ❌ DON'T — the wait is redundant
TestStep.macSendHookEvent(...)
TestStep.wait(seconds: 3)
TestStep.iosWaitForElement(.labelContains("Prompt Submitted"), timeout: 5)

// ✅ DO — let waitForElement own the timing
TestStep.macSendHookEvent(...)
TestStep.iosWaitForElement(.labelContains("Prompt Submitted"), timeout: 5)
```

### Rule: `iosTap` / `macClickButton` already wait for their target

Both have an internal element wait (`macClickButton` waits up to 5s via `waitForAXElement`; `iosTap` falls back to `waitForElement(timeout: 5)` when the element isn't present yet). A `wait` *before* them is almost never useful:

```swift
// ❌ DON'T
TestStep.iosWaitForElement(.label("Sessions"), timeout: 5)
TestStep.wait(seconds: 1)
TestStep.iosTap(.label("Sessions"))

// ✅ DO
TestStep.iosWaitForElement(.label("Sessions"), timeout: 5)
TestStep.iosTap(.label("Sessions"))
```

### Rule: prefer "wait for new state" over "wait then disappear"

`iosWaitForElementToDisappear` returns immediately if the element *hasn't appeared yet*. Don't rely on it as a "loading finished" signal in isolation — wait for the post-loaded element to appear instead, which proves the loading completed:

```swift
// ❌ Risky — if "Loading projects" hasn't shown yet, returns immediately
TestStep.iosTap(.label("New Session"))
TestStep.iosWaitForElementToDisappear(.labelContains("Loading projects"), timeout: 15)

// ✅ Reliable — waiting for a project to appear proves the loading finished
TestStep.iosTap(.label("New Session"))
TestStep.iosWaitForElement(.labelContains("New Terminal"), timeout: 15)
```

### When a fixed `wait` is genuinely needed

Some situations have no observable signal:

- **Before a screenshot whose visual state depends on time-based animation** (cursor blink, debounced redraw, scroll deceleration). Even here, prefer `macWaitForElement(titled: "expected text")` when the screenshot is meant to assert a specific terminal output is rendered.
- **After `tmuxRunCommand` / `tmuxSendKeys` when you immediately call `tmuxCapturePaneContent`** — capturing doesn't poll, so let the terminal render first (typically 0.3–1s). For longer commands, use `waitForTmuxDisplayMessage` to poll for a known marker in the output.
- **After resize/move window operations that fan out to a debouncer** (e.g. 200ms tmux resize debounce + propagation). When possible, replace with `waitForTmuxDisplayMessage` / `waitForTmuxDisplayMessageNotEqual` keyed on `#{pane_width}x#{pane_height}` so the test moves on the instant the resize lands.

```swift
// For tmux state changes: poll display-message instead of guessing
TestStep.waitForTmuxDisplayMessage(
    target: "test:0",
    format: "#{pane_title}",
    contains: "My Title",
    timeout: 10
)

// For "wait until a value changes" when the target value isn't known up front
TestStep.waitForTmuxDisplayMessageNotEqual(
    target: "test:0",
    format: "#{pane_width}x#{pane_height}",
    notEqualTo: "80x24",
    timeout: 10
)
```

### Quick checklist when adding a `wait(seconds:)`

1. Is the very next step a `*WaitFor*` / `verifyServerHasPairings`? → delete the wait.
2. Is the very next step `iosTap` / `macClickButton`? → almost always delete the wait.
3. Are you waiting for a UI element you can name? → replace with `*WaitForElement*`.
4. Are you waiting for a tmux pane property? → replace with `waitForTmuxDisplayMessage*`.
5. Are you waiting for a file to be written? → replace with `waitForFileContains`.
6. None of the above → leave the `wait` but keep the duration tight (0.3–1s is usually enough).

Issue #539 removed ~430 redundant waits across the scenario suite using these rules; the same checklist applies to every new scenario.
