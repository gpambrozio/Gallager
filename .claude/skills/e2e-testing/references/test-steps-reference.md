# Test Steps Reference

Complete reference for all `TestStep` enum cases defined in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/DSL/TestScenario.swift`.

## Instance parameter on macOS steps

**Every** macOS step accepts an `instance: Int = 0` parameter (omitted from the signatures below for brevity unless noted otherwise). Instance `0` is the primary app; instances `1+` are additional Mac apps used in two-Mac pairing scenarios. The orchestrator derives ports and tmux-socket-adjacent files automatically per instance.

```swift
TestStep.launchMacApp()                               // instance 0 (default)
TestStep.launchMacApp(instance: 1)                    // second Mac
TestStep.macClickButton(titled: "Add Host", instance: 1)
TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)
```

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
Disconnect a device's WebSocket connections on the server side. `E2EDeviceType` is `.host` or `.viewer`. Used to simulate transient network drops for reconnection testing — the device is free to reconnect immediately.

### `serverBlockDevice(_ device: E2EDeviceType)`
Block a device type from connecting *and* disconnect any existing connections. New WebSocket connections from this device type are rejected until `serverUnblockDevice` is called. Use to model a sustained outage (e.g. host crash) where the device should not be able to silently reconnect during the assertion window.

### `serverUnblockDevice(_ device: E2EDeviceType)`
Unblock a previously-blocked device type so it can reconnect.

### `waitForNoPairings(timeout: TimeInterval = 15)`
Wait until the server reports zero active pairings. Use before `verifyServerHasPairings(count: 0)` for race-condition-safe unpair verification.

### `stopServer`
Stop the server and clean up `pairs.json`. Normally not needed - orchestrator handles cleanup.

## iOS Simulator Steps

### `launchIOSApp(appVersion: String? = nil, minRequiredPartnerVersion: String? = nil)`
Boot the simulator (if needed), install the iOS app, launch it with `--e2e-test --server-url ws://127.0.0.1:8765`, and start the XCUITest runner. Must call `startServer` first.

Pass `appVersion` and/or `minRequiredPartnerVersion` to simulate an older or mismatched build for version-compatibility testing. They map to the iOS app's `VersionCompatibility` overrides; both nil (default) means "use the build's real values".

### `terminateIOSApp`
Terminate the running iOS app. Normally not needed - orchestrator handles cleanup.

### `uninstallIOSApp`
Terminate and uninstall the iOS app from the simulator. Use at scenario start to ensure clean state.

### `iosWaitForElement(_ query: ElementQuery, timeout: TimeInterval = 10)`
Wait for a UI element matching the query to appear in the accessibility tree. Default timeout: 10 seconds. Polls the XCUITest runner's `/viewHierarchy` endpoint.

### `iosTap(_ query: ElementQuery)`
Wait for an element matching the query to appear, then tap its center coordinates. Combines wait + tap in a single step.

### `iosTapCoordinate(x: CGFloat, y: CGFloat)`
Tap at raw iOS point coordinates. Use sparingly — prefer element queries for maintainability. Useful for dismissing menus by tapping outside them.

### `iosType(text: String)`
Type text into the currently focused field. Supports `${variable}` interpolation.

### `iosSwipeLeft(_ query: ElementQuery)`
Wait for an element matching the query, then perform a left swipe gesture on it. Used for revealing swipe actions (e.g., delete buttons on list rows).

### `iosSwipe(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat, duration: TimeInterval = 0.3)`
Perform a swipe gesture between two raw simulator coordinates. Useful for testing pan-driven UI like terminal scrolling where the gesture's direction and distance matter, not the targeted element.

### `iosWaitForElementToDisappear(_ query: ElementQuery, timeout: TimeInterval = 10)`
Wait for a UI element to no longer be present in the accessibility tree. Useful for waiting for loading spinners or transitional text (`"Connecting"`) to disappear.

### `iosScreenshot(label: String, compare: Bool = true, tolerance: Double = 0.5, perPixelThreshold: Double = 0.3)`
Take a screenshot of the iOS simulator. The label is auto-prefixed with a zero-padded counter (`01-`, `02-`, …) that resets per scenario — do not add manual number prefixes. By default the screenshot is compared against a stored baseline; pass `compare: false` only when the screen would change between runs (e.g. live timestamps, animation in flight). See `docs/e2e-testing.md` for screenshot comparison details.

`tolerance` is the maximum percentage of differing pixels allowed (default 0.5%). `perPixelThreshold` is how different a single pixel can be before it's considered "different" (default 0.3, on a 0.0–1.0 scale).

### `iosLogUI`
Dump the full iOS accessibility tree to the console log. For debugging only — helps discover element labels, roles, and identifiers when writing queries.

### `iosReadClipboard(storeAs: String)`
Read the iOS simulator's general pasteboard and store its contents in the execution context under the given key. Use to assert clipboard sync from the host (e.g. OSC 52 → viewer pasteboard).

### `iosClearClipboard`
Clear the iOS simulator's general pasteboard (pipes `/dev/null` into `simctl pbcopy`). Use before screenshotting views whose appearance depends on clipboard contents — most notably SwiftUI's `PasteButton`, which auto-enables when the pasteboard carries matching payload — so baselines don't drift with whatever the simulator pasteboard happened to be holding.

### `iosSetAppVersion(appVersion: String?, minRequiredPartnerVersion: String?)`
Update the iOS app's `VersionCompatibility` overrides at runtime and kick a reconnect. `nil` clears the override; a non-nil value replaces it. Used by version-mismatch scenarios to simulate an in-place "app update" without relaunching.

## macOS App Steps

All macOS steps below accept a trailing `instance: Int = 0` parameter (see "Instance parameter" section above). It is omitted from the descriptions for readability.

### `launchMacApp(appVersion: String? = nil, minRequiredPartnerVersion: String? = nil)`
Launch the macOS app with `--e2e-test --server-url ws://127.0.0.1:8765 --tmux-socket <path>` arguments. The `--server-url` flag is always included to prevent accidental production connections — for macOS-only scenarios, the app simply fails to connect (which is fine).

`appVersion`/`minRequiredPartnerVersion` work the same as on `launchIOSApp`.

### `terminateMacApp`
Terminate the macOS app using `osascript -e 'quit app "Gallager"'`. Use at scenario start for clean state, or rely on orchestrator cleanup at the end.

### `macActivate`
Bring the macOS app instance frontmost with its key window. Use before steps that depend on `NSApp.isActive` or `window.isKeyWindow` (e.g. when a previous step on a different instance stole focus).

### `macOpenSettings`
Open the Settings window via the status item menu.

### `macWaitForWindow(titled: String, timeout: TimeInterval = 5)`
Wait for a macOS window with the given title to appear (substring/help/value match — see `macWaitForElement`).

### `macAssertWindowTitle(equals: String, timeout: TimeInterval = 5)`
Wait for any top-level macOS window whose title **equals** the given string exactly. Use when asserting on a specific `navigationTitle` to avoid substring collisions with similarly-named windows.

### `macSelectSettingsTab(_ tabName: String)`
Click a tab in the Settings window sidebar. The tab name matches the sidebar label (e.g., `"Remote Access"`, `"General"`, `"Remote Hosts"`).

### `macClickButton(titled: String)`
Click a button or element by its title, label, or `.help()` attribute. Uses the in-app test accessibility server (port 18081 + instance offset) which searches:
1. Toolbar items by label
2. Sidebar/outline rows by walking NSView hierarchy
3. Accessibility tree recursively by title, label, value, or help

For `List`/`OutlineGroup` row selection that the AXPress fallback cannot drive (selection on click), prefer `macCGClick`.

### `macClickMenuItem(menuButtonTitle: String, itemTitle: String)`
Click a menu trigger button, then click a menu item. Use for dropdown menus attached to toolbar buttons.

### `macCGClick(titled: String)`
CGEvent left-click on an element (real synthesized mouse click). Bypasses `accessibilityPerformPress` — use for selecting items in SwiftUI `List`/`OutlineGroup` where AXPress doesn't update selection state, or for any element that responds to actual mouse clicks but not press actions.

### `macRightClick(titled: String)`
Right-click an element to open its context menu. The follow-up menu item must then be clicked separately, or use `macContextMenuClick` for the combined operation.

### `macContextMenuClick(elementTitle: String, menuItem: String)`
Right-click an element and then click the named menu item from the resulting context menu. Use for `.contextMenu` actions on rows, tabs, or files.

### `macPressTab` / `macPressEscape` / `macPressReturn` / `macPressSpace`
Send the corresponding key. `Tab` cycles focus in dialogs, `Escape` dismisses dialogs, `Return` confirms the default action, `Space` activates the focused button.

### `macSelectAll`
Send Cmd+A to select all text in the focused field. Use before `macType` to replace existing field content.

### `macUnpair`
Trigger unpair on the first paired viewer via the test HTTP endpoint. Use when the macOS unpair button is inside an NSMenu (invisible to the accessibility tree).

### `macSetAppVersion(appVersion: String?, minRequiredPartnerVersion: String?)`
Update the macOS app's `VersionCompatibility` overrides at runtime and kick a reconnect (counterpart to `iosSetAppVersion`).

### `macReadClipboard(storeAs: String)`
Read the macOS clipboard contents and store them in the execution context under the given key. Use with `${key}` interpolation in subsequent steps.

### `macWaitForElement(titled: String, timeout: TimeInterval = 10)`
Wait for a text element to appear in the macOS app's accessibility tree. Matches by title, label, value (contains), or help (exact). Useful for verifying status text like "Connected" or dimension labels like "80x24".

### `macWaitForElementToDisappear(titled: String, timeout: TimeInterval = 10)`
Wait for a text element to no longer be in the macOS app's accessibility tree. Mirror of `macWaitForElement`.

### `macWaitForElementQuery(_ query: ElementQuery, timeout: TimeInterval = 10)`
Wait for an element matching an `ElementQuery` to appear in the macOS app's accessibility tree. Use for precise matching (e.g. a toggle with a specific help text AND value). Example: `.allOf([.help("Auto-resize tmux pane..."), .valueContains("1")])` to verify a toggle is checked.

### `macWaitForElementQueryToDisappear(_ query: ElementQuery, timeout: TimeInterval = 10)`
Wait for an element matching an `ElementQuery` to disappear from the macOS app's accessibility tree.

### `macCloseWindow(titled: String)`
Close a macOS window by title via its AXCloseButton. Useful for closing the Settings window after toggling a preference, to avoid it interfering with window-order-sensitive steps like `macResizeWindow`.

### `macOpenPanesWindow`
Open the Panes window via the status item menu.

### `macMoveWindow(x: Int, y: Int)`
Move the macOS app's frontmost window to the given screen position.

### `macResizeWindow(width: Int, height: Int)`
Resize the macOS app's frontmost window to the specified pixel dimensions.

### `macSetSidebarWidth(_ width: Int)`
Set the sidebar width of the `NavigationSplitView`. Used by `Shortcut.openPanesWindow` to enforce a deterministic 250-pt sidebar before screenshots.

### `macFocusElement(titled: String)`
Focus a text field by title so subsequent typing routes into it. Use when the orchestrator needs to type into a specific field that isn't already first responder (e.g. a "Pairing Code" field in a sheet).

### `macType(text: String, pressReturn: Bool = false, charDelay: TimeInterval = 0)`
Type text into the macOS app via AppleScript `keystroke`. Supports `${variable}` interpolation. Set `pressReturn: true` to press Return after typing (useful for terminal commands). Set `charDelay > 0` to type character-by-character with delays between keystrokes — required when typing into remote terminals that need time to round-trip each key.

### `macScrollUp(pages: Int = 1)`
Scroll the macOS terminal view up by the given number of pages (Page Up key).

### `macScrollWheel(deltaY: Int32, count: Int = 3)`
Send scroll-wheel events to the macOS app window via CGEvent. `deltaY > 0` scrolls up, `< 0` scrolls down. `count` is how many events to send.

### `macClickAtPoint(x: Double, y: Double)`
Click at a specific screen coordinate inside the macOS app. For places where no accessibility-tree target exists (e.g. clicking on terminal cells).

### `macDrag(fromX: Double, fromY: Double, toX: Double, toY: Double)`
Drag from one screen coordinate to another inside the macOS app. Used for terminal text selection in mouse mode and similar interactions.

### `macScreenshot(label: String, compare: Bool = true, tolerance: Double = 2, perPixelThreshold: Double = 0.02)`
Take a screenshot of the macOS app window. The label is auto-prefixed with a zero-padded counter (`01-`, `02-`, …) that resets per scenario. By default compares against a stored baseline.

The mac defaults (`tolerance: 2%`, `perPixelThreshold: 0.02`) are looser than iOS because color-space normalisation introduces small per-pixel differences that don't represent UI changes. Bump `tolerance` higher (e.g. 5) for screens that capture both apps simultaneously where the iOS simulator state is non-deterministic.

## Tmux Steps

### `tmuxCreateSession(name: String, width: Int, height: Int)`
Create a tmux session on the test socket with the given name and initial dimensions. The tmux socket path is managed by the orchestrator (default `/tmp/claudespy-e2e/claudespy-e2e.sock`).

### `tmuxStorePaneDimensions(target: String, widthKey: String, heightKey: String)`
Query a tmux pane's current dimensions and store width/height in the execution context. The `target` uses tmux target format (e.g., `"session-name:0.0"`).

### `tmuxStorePaneId(target: String, storeAs: String)`
Query the tmux pane ID (e.g. `%0`) for a target and store it in the execution context. Required by `macSendHookEvent` which addresses panes by their tmux ID.

### `tmuxCapturePaneContent(target: String, storeAs: String)`
Capture the visible content of a tmux pane and store it in the execution context. Use with `assertStoredContains` / `assertStoredNotContains` to verify what the terminal is rendering without taking a screenshot.

### `tmuxSendKeys(target: String, keys: String, literal: Bool = false)`
Send keys to a tmux pane on the test socket (bypasses the macOS app input path). Set `literal: true` to send raw text instead of letting tmux interpret the keys (e.g. `"Enter"` is the Enter key when literal is false; the four-character string `"Enter"` when true). Most callers should use `Shortcut.tmuxRunCommand` instead of pairing this with a separate Enter step.

### `tmuxCommand(arguments: [String])`
Run an arbitrary tmux command on the test socket (e.g., `["split-window", "-h", "-t", "session:0"]`). Use for split/select/kill operations that don't fit `send-keys`.

### `tmuxStoreDisplayMessage(target: String, format: String, storeAs: String)`
Query a tmux format string via `display-message -p` and store the output in the execution context. Use to read pane/window/session attributes (e.g. `"#{window_active}"`, `"#{pane_title}"`) for assertions.

### `waitForTmuxDisplayMessage(target: String, format: String, contains: String, timeout: TimeInterval = 20)`
Poll a tmux format string via `display-message -p` until the result contains the given substring. Use to wait for a tmux state change (e.g. window title update) without fixed sleeps.

## Hook Events

### `macSendHookEvent(json: String, tmuxPane: String, projectPath: String? = nil)`
POST a hook event to the macOS app's real hook server (`/api/hooks`). The `json` parameter is the raw JSON body (supports `${var}` interpolation, so you can embed `${paneId}` from `tmuxStorePaneId`). `tmuxPane` and `projectPath` are sent as query parameters. The server port is read from the orchestrator's `hookPortFile`.

This step lets scenarios drive Claude session lifecycle (`SessionStart`, `Stop`, `Notification`, `PermissionRequest`, etc.) end-to-end without invoking real Claude. Use to test session list updates, mark-handled flows, yolo mode, ask-user-question, etc.

## Assertion Steps

### `assertStoredEqual(key: String, otherKey: String)`
Assert that two values stored in the execution context are equal. Fails the scenario if they differ.

### `assertStoredNotEqual(key: String, otherKey: String)`
Assert that two values stored in the execution context are NOT equal.

### `assertStoredContains(key: String, substring: String)`
Assert that a stored value contains the given substring (after `${...}` interpolation in the substring). Use to verify terminal pane content captured via `tmuxCapturePaneContent`, clipboard contents read via `iosReadClipboard` / `macReadClipboard`, file contents from `readFile`, etc.

### `assertStoredNotContains(key: String, substring: String)`
Negation of `assertStoredContains`. Use to verify a value is *not* present (e.g. the previous clipboard wasn't overwritten while iOS was off-screen).

## Script Injection

### `injectScript(name: String)`
Copy a bundled script from `ClaudeSpyE2ELib/Scenarios/Scripts/` to `$TMPDIR`. The orchestrator removes it automatically when the scenario ends, even on failure. Reference the script in tmux commands as `$TMPDIR/<name>` (the tmux server inherits the orchestrator's `TMPDIR`).

Use for terminal rendering tests where Python helpers draw deterministic output (tables, emojis, truecolor, kitty keyboard probes, …). Bundled scripts already include `draw_table.py`, `editor_trigger.py`, `emoji_tables.py`, `footer_test.py`, `keystroke_logger.py`, `kitty_keyboard_test.py`, `mouse_test.py`, `truecolor.py`. Add new ones to the same directory and they get bundled as SPM resources automatically.

## General Steps

### `wait(seconds: TimeInterval)`
Sleep for the specified duration. **Avoid this whenever a state-driven wait works** — fixed sleeps pay their full duration whether the UI needed it or not, and they compound across the scenario suite.

Specifically:
- **Never put `wait` immediately before a `*WaitFor*` step** (`iosWaitForElement`, `macWaitForElement`, `macWaitForElementQuery`, `macWaitForWindow`, `waitForHostConnected`, `waitForViewerConnected`, `waitForNoPairings`, `verifyServerHasPairings`, `waitForTmuxDisplayMessage*`, `waitForFileContains`) — those steps already poll until the condition is met.
- **Avoid `wait` before `iosTap` / `macClickButton`** — both wait up to 5s for their target element internally.
- **Don't use `waitForElementToDisappear` as a "loading finished" signal** without a separate signal that the element was visible — if it never appeared, the step returns immediately. Prefer waiting for the post-loaded element.

A fixed `wait` is still appropriate when there's no observable signal — typically before a screenshot of an animated state (cursor blink, scroll deceleration), between `tmuxRunCommand` and an immediate `tmuxCapturePaneContent`, or after a debounced resize where you can't easily express the post-state. Keep those durations tight (0.3–1s).

See `references/patterns.md` "Waiting for UI Transitions" for the full checklist.

### `storeValue(key: String, value: String)`
Store a literal string value in the execution context for use in assertions or interpolation.

### `readFile(path: String, storeAs: String)`
Read a file's contents and store them in the execution context. Path supports `${var}` interpolation. Returns an empty string if the file is missing (does not fail the step). Pair with `assertStoredContains` to verify file content.

### `waitForFileContains(path: String, substring: String, storeAs: String, timeout: TimeInterval = 20, pollInterval: TimeInterval = 1)`
Poll a file until it contains the given substring, then store its contents. Useful for waiting on side-effects written by the app (e.g. log files, generated artifacts) without racing.

### `log(_ message: String)`
Log a message to the console. Supports `${variable}` interpolation. Use for phase markers and to surface stored values during debugging.
