# Test Steps Reference

Complete reference for all `TestStep` enum cases defined in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/DSL/TestScenario.swift`.

## Server Steps

### `startServer`
Start the in-process Vapor relay server on port 8765. Must be called before launching apps.

### `verifyServerHealth`
Poll the server health endpoint until it responds. Call after `startServer`.

### `verifyServerHasPairings(count: Int)`
Assert the server has exactly `count` active pairings. Fails immediately if count doesn't match.

### `waitForHostConnected(timeout: TimeInterval = 15)`
Wait for the macOS host to connect to the server via WebSocket. Default timeout: 15 seconds.

### `waitForViewerConnected(timeout: TimeInterval = 15)`
Wait for the iOS viewer to connect to the server via WebSocket. Default timeout: 15 seconds.

### `serverDisconnectDevice(_ device: E2EDeviceType)`
Disconnect a device's WebSocket connections on the server side. `E2EDeviceType` is `.host` or `.viewer`. Used to simulate network disconnections for reconnection testing.

### `waitForNoPairings(timeout: TimeInterval = 15)`
Wait until the server reports zero active pairings. Use before `verifyServerHasPairings(count: 0)` for race-condition-safe unpair verification.

### `stopServer`
Stop the server and clean up `pairs.json`. Normally not needed - orchestrator handles cleanup.

## iOS Simulator Steps

### `launchIOSApp`
Boot the simulator (if needed), install the iOS app, launch it with `--e2e-test --server-url ws://127.0.0.1:8765`, and start the XCUITest runner. Must call `startServer` first.

### `terminateIOSApp`
Terminate the running iOS app. Normally not needed - orchestrator handles cleanup.

### `uninstallIOSApp`
Terminate and uninstall the iOS app from the simulator. Use at scenario start to ensure clean state.

### `iosWaitForElement(_ query: ElementQuery, timeout: TimeInterval = 10)`
Wait for a UI element matching the query to appear in the accessibility tree. Default timeout: 10 seconds. Polls the XCUITest runner's `/viewHierarchy` endpoint.

### `iosTap(_ query: ElementQuery)`
Wait for an element matching the query to appear, then tap its center coordinates. Combines wait + tap in a single step.

### `iosTapCoordinate(x: CGFloat, y: CGFloat)`
Tap at raw iOS point coordinates. Use sparingly - prefer element queries for maintainability.

### `iosType(text: String)`
Type text into the currently focused field. Supports `${variable}` interpolation.

### `iosSwipeLeft(_ query: ElementQuery)`
Wait for an element matching the query, then perform a left swipe gesture on it. Used for revealing swipe actions (e.g., delete buttons on list rows).

### `iosWaitForElementToDisappear(_ query: ElementQuery, timeout: TimeInterval = 10)`
Wait for a UI element to no longer be present in the accessibility tree. Useful for waiting for loading spinners or transitional text to disappear.

### `iosScreenshot(label: String, compare: Bool = true, tolerance: Double = 0.0)`
Take a screenshot of the iOS simulator. The label is auto-prefixed with a zero-padded counter (`01-`, `02-`, etc.) that resets per scenario — do not add manual number prefixes. By default, the screenshot is compared against a stored baseline (see `docs/e2e-testing.md` for screenshot comparison details). Pass `compare: false` for capture-only screenshots.

### `iosLogUI`
Dump the full iOS accessibility tree to the console log. For debugging only - helps discover element labels, roles, and identifiers when writing queries.

## macOS App Steps

### `launchMacApp`
Launch the macOS app with `--e2e-test --server-url ws://127.0.0.1:8765 --tmux-socket <path>` arguments. The `--server-url` flag is always included to prevent accidental production connections. For macOS-only scenarios, a running server is not required - the app will simply fail to connect (which is fine).

### `terminateMacApp`
Terminate the macOS app using `osascript -e 'quit app "Gallager"'`. Use at scenario start for clean state, or orchestrator handles it in cleanup.

### `macOpenSettings`
Open the Settings window via the status item menu.

### `macWaitForWindow(titled: String, timeout: TimeInterval = 5)`
Wait for a macOS window with the given title to appear. Default timeout: 5 seconds.

### `macSelectSettingsTab(_ tabName: String)`
Click a tab in the Settings window sidebar. The tab name matches the sidebar label (e.g., `"Remote Access"`, `"General"`).

### `macClickButton(titled: String)`
Click a button or element by its title, label, or `.help()` attribute. Uses the test accessibility server (port 18081) which searches:
1. Toolbar items by label
2. Sidebar/outline rows by walking NSView hierarchy
3. Accessibility tree recursively by title, label, value, or help

### `macClickMenuItem(menuButtonTitle: String, itemTitle: String)`
Click a menu trigger button, then click a menu item. Use for dropdown menus attached to toolbar buttons.

### `macUnpair`
Trigger unpair on the first paired viewer via the test HTTP endpoint (port 18081). Use when the macOS unpair button is inside an NSMenu (invisible to accessibility tree).

### `macReadClipboard(storeAs: String)`
Read the macOS clipboard contents and store them in the execution context under the given key. Use with `${key}` interpolation in subsequent steps.

### `macWaitForElement(titled: String, timeout: TimeInterval = 10)`
Wait for a text element to appear in the macOS app's accessibility tree. Useful for verifying status text like "Connected" or dimension labels like "80x24".

### `macOpenPanesWindow`
Open the Panes window via the status item menu.

### `macResizeWindow(width: Int, height: Int)`
Resize the macOS app's frontmost window to the specified pixel dimensions.

### `macType(text: String, pressReturn: Bool = false)`
Type text into the macOS app via AppleScript `keystroke`. Supports `${variable}` interpolation. Set `pressReturn: true` to press Return after typing (useful for terminal commands).

### `macScreenshot(label: String, compare: Bool = true, tolerance: Double = 0.0)`
Take a screenshot of the macOS app window. The label is auto-prefixed with a zero-padded counter (`01-`, `02-`, etc.) that resets per scenario — do not add manual number prefixes. By default, the screenshot is compared against a stored baseline (see `docs/e2e-testing.md` for screenshot comparison details). Pass `compare: false` for capture-only screenshots. When `compare: false`, screenshot errors are non-fatal (logged as warnings).

## Tmux Steps

### `tmuxCreateSession(name: String, width: Int, height: Int)`
Create a tmux session on the test socket with the given name and initial dimensions. The tmux socket path is managed by the orchestrator (default `/tmp/claudespy-e2e.sock`).

### `tmuxStorePaneDimensions(target: String, widthKey: String, heightKey: String)`
Query a tmux pane's current dimensions and store width/height in the execution context. The `target` uses tmux target format (e.g., `"session-name:0.0"`).

## Assertion Steps

### `assertStoredEqual(key: String, otherKey: String)`
Assert that two values stored in the execution context are equal. Fails the scenario if they differ.

### `assertStoredNotEqual(key: String, otherKey: String)`
Assert that two values stored in the execution context are NOT equal. Fails the scenario if they match.

## General Steps

### `wait(seconds: TimeInterval)`
Sleep for the specified duration. Use after actions that trigger UI transitions or network operations. Typical values: 0.5-3 seconds for UI, 3-5 for network operations.

### `storeValue(key: String, value: String)`
Store a literal string value in the execution context for use in assertions or interpolation.

### `log(_ message: String)`
Log a message to the console. Supports `${variable}` interpolation. Use for phase markers and debugging.
