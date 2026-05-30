import CoreGraphics
import Foundation

/// A named collection of test steps
public struct TestScenario: Sendable {
    public let name: String
    public let tags: [String]
    public let steps: [TestStep]

    public init(name: String, tags: [String] = [], steps: [TestStep]) {
        self.name = name
        self.tags = tags
        self.steps = steps
    }
}

/// Device type for E2E server-side operations
public enum E2EDeviceType: String, Sendable {
    case host
    case viewer
}

/// Keyboard modifier flags accepted by ``TestStep/macPressKey(_:modifiers:instance:)``.
/// Maps directly to `CGEventFlags` inside the macOS driver.
///
/// Combine multiple modifiers with array-literal syntax,
/// e.g. `[.command, .shift]`.
public struct KeyboardModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyboardModifiers(rawValue: 1 << 0)
    public static let shift = KeyboardModifiers(rawValue: 1 << 1)
    public static let option = KeyboardModifiers(rawValue: 1 << 2)
    public static let control = KeyboardModifiers(rawValue: 1 << 3)
}

extension KeyboardModifiers: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.command) { parts.append("command") }
        if contains(.shift) { parts.append("shift") }
        if contains(.option) { parts.append("option") }
        if contains(.control) { parts.append("control") }
        return parts.isEmpty ? "[]" : parts.joined(separator: "+")
    }
}

/// A key to press via ``TestStep/macPressKey(_:modifiers:instance:)``.
///
/// Use the named cases for non-printable keys (Tab, Escape, …) and
/// `.character(_)` for printable characters whose virtual key code the
/// macOS driver can resolve (letters, digits, common punctuation).
public enum Key: Sendable, Equatable {
    case tab
    case escape
    case `return`
    case space
    case downArrow
    case upArrow
    case character(Character)
}

/// An individual test step that the orchestrator executes
public enum TestStep: Sendable {
    // MARK: - Server

    /// Start the in-process Vapor server
    case startServer
    /// Verify the server is healthy
    case verifyServerHealth
    /// Verify the number of active pairings
    case verifyServerHasPairings(count: Int)
    /// Wait for the macOS host to connect to the server via WebSocket
    case waitForHostConnected(timeout: TimeInterval = 15)
    /// Wait for the iOS viewer to connect to the server via WebSocket
    case waitForViewerConnected(timeout: TimeInterval = 15)
    /// Disconnect a device type's WebSocket connections on the server
    case serverDisconnectDevice(E2EDeviceType)
    /// Block a device type from connecting and disconnect existing connections.
    /// New WebSocket connections from this device type will be rejected until unblocked.
    case serverBlockDevice(E2EDeviceType)
    /// Unblock a device type, allowing connections again
    case serverUnblockDevice(E2EDeviceType)
    /// Wait until the server has no active pairings
    case waitForNoPairings(timeout: TimeInterval = 15)
    /// Stop the server
    case stopServer

    // MARK: - APNs E2E (Relay-Side Push Recording)

    /// Wait until the relay's APNs E2E push log has at least `count` entries.
    /// The log is populated by `APNsService` when `APNS_E2E_LOG_PATH` is set
    /// (always true under the E2E `ServerDriver`).
    case waitForAPNSPushCount(_ count: Int, timeout: TimeInterval = 10)

    /// Verify the last entry in the APNs push log. `aggregatedBadge` is the
    /// `aps.badge` value the relay would set on the outgoing APS payload —
    /// the assertion target for the badge-aggregation scenarios. `pushType`
    /// should be `"alert"` for event pushes or `"background"` for silent
    /// badge-only updates.
    case verifyLastAPNSPush(aggregatedBadge: Int?, silent: Bool, pushType: String)

    /// Delete the APNs push log file so subsequent
    /// `verifyLastAPNSPush` / `waitForAPNSPushCount` assertions only see
    /// pushes recorded after this point.
    case clearAPNSPushLog

    // MARK: - Synthetic Pairing (E2E Test-Only)

    /// Read the first active pair's viewer identity from the relay's
    /// `PairingService` into context keys: `${storePrefix}DeviceId`,
    /// `${storePrefix}DeviceName`, `${storePrefix}PublicKey`,
    /// `${storePrefix}PublicKeyId`, `${storePrefix}PushToken`. Used by badge
    /// aggregation scenarios to "borrow" the iOS viewer's key material before
    /// synthesizing a second host's pair completion.
    case serverReadFirstViewerIdentity(storePrefix: String = "viewer")

    /// Complete a host's pending pairing as if a viewer had submitted the
    /// `code`, using the viewer fields previously stored by
    /// `serverReadFirstViewerIdentity(storePrefix:)`. Registers `pushToken`
    /// on the new pair so the relay's badge aggregation sees both pairs as
    /// siblings of the same APNs device.
    case serverCompletePairingAsViewer(
        codeKey: String,
        pushTokenKey: String,
        viewerKeysPrefix: String = "viewer",
        storeAs: String
    )

    /// Inject a push to the relay's `APNsService` as if a host had sent it.
    /// `pairIdKey` looks up the target pair in the execution context (typically
    /// stored by `serverCompletePairingAsViewer`). Used by badge-aggregation
    /// scenarios where the second host isn't a real running Mac.
    case serverInjectPush(pairIdKey: String, hostBadge: Int?, silent: Bool)

    // MARK: - iOS Simulator

    /// Launch the iOS app in the simulator. Pass optional version overrides to simulate
    /// old or mismatched app versions for compatibility testing.
    case launchIOSApp(appVersion: String? = nil, minRequiredPartnerVersion: String? = nil)
    /// Terminate the iOS app
    case terminateIOSApp
    /// Uninstall the iOS app from the simulator
    case uninstallIOSApp
    /// Wait for an iOS UI element to appear
    case iosWaitForElement(ElementQuery, timeout: TimeInterval = 10)
    /// Tap an iOS UI element
    case iosTap(ElementQuery)
    /// Long-press an iOS element to open SwiftUI context menus. Default
    /// duration matches the system's long-press threshold with margin.
    case iosLongPress(ElementQuery, duration: TimeInterval = 1)
    /// Tap at raw iOS coordinates
    case iosTapCoordinate(x: CGFloat, y: CGFloat)
    /// Type text into the iOS app
    case iosType(text: String)
    /// Swipe left on an iOS UI element
    case iosSwipeLeft(ElementQuery)
    /// Perform a swipe gesture between two raw simulator coordinates. Useful
    /// for testing pan-driven UI like terminal scrolling where the gesture
    /// direction and distance matter, not the targeted element.
    case iosSwipe(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat, duration: TimeInterval = 0.3)
    /// Wait for an iOS UI element to disappear
    case iosWaitForElementToDisappear(ElementQuery, timeout: TimeInterval = 10)
    /// Take an iOS screenshot, optionally comparing against a stored baseline
    case iosScreenshot(label: String, compare: Bool = true, tolerance: Double = 0.5, perPixelThreshold: Double = 0.3)
    /// Dump the iOS AX tree to the log (for debugging)
    case iosLogUI
    /// Read the iOS simulator clipboard and store in context
    case iosReadClipboard(storeAs: String)
    /// Clear the iOS simulator clipboard. Useful before screenshotting views
    /// whose appearance depends on clipboard contents (e.g. SwiftUI's
    /// `PasteButton`, which is enabled whenever the pasteboard has matching
    /// payload). Forces the disabled state so baselines are deterministic.
    case iosClearClipboard
    /// Update the iOS app's `VersionCompatibility` overrides at runtime and kick
    /// a reconnect. `nil` clears the override; a non-nil value replaces it. Used
    /// by version-mismatch scenarios to simulate an in-place "app update".
    case iosSetAppVersion(appVersion: String?, minRequiredPartnerVersion: String?)

    // MARK: - macOS App
    //
    // All macOS steps accept an `instance` parameter (default 0) to target
    // different app instances. Instance 0 is the primary app; instance 1+
    // are additional instances (e.g. for Mac-to-Mac pairing scenarios).
    // Ports and file paths are derived automatically from the instance number.

    /// Launch the macOS app. Pass optional version overrides to simulate old or mismatched
    /// app versions for compatibility testing.
    case launchMacApp(instance: Int = 0, appVersion: String? = nil, minRequiredPartnerVersion: String? = nil)
    /// Terminate the macOS app
    case terminateMacApp(instance: Int = 0)
    /// Activate the macOS app instance so it becomes frontmost with its key window.
    /// Use before steps that depend on `NSApp.isActive` or `window.isKeyWindow`.
    case macActivate(instance: Int = 0)
    /// Open Settings window
    case macOpenSettings(instance: Int = 0)
    /// Close a window by title via its close button
    case macCloseWindow(titled: String, instance: Int = 0)
    /// Wait for a macOS window
    case macWaitForWindow(titled: String, timeout: TimeInterval = 5, instance: Int = 0)
    /// Wait for any top-level macOS window whose title equals the given string exactly.
    /// Use when asserting on `navigationTitle` to avoid substring collisions.
    case macAssertWindowTitle(equals: String, timeout: TimeInterval = 5, instance: Int = 0)
    /// Select a Settings tab
    case macSelectSettingsTab(String, instance: Int = 0)
    /// Click a button by title
    case macClickButton(titled: String, instance: Int = 0)
    /// Click a menu trigger button then click a menu item
    case macClickMenuItem(menuButtonTitle: String, itemTitle: String, instance: Int = 0)
    /// Press a key with optional modifiers via CGEvent.
    ///
    /// Use named ``Key`` cases for non-printable keys (Tab, Escape, Return,
    /// Space, arrow keys) and `.character(_)` for any printable character
    /// whose virtual key code the driver can resolve (letters, digits,
    /// common punctuation).
    ///
    /// Examples:
    /// - `macPressKey(.escape)` — dismiss a dialog
    /// - `macPressKey(.return)` — confirm the default action
    /// - `macPressKey(.tab)` — cycle focus
    /// - `macPressKey(.character("a"), modifiers: .command)` — Cmd+A select all
    /// - `macPressKey(.character("]"), modifiers: [.command, .shift])` — app shortcut
    case macPressKey(Key, modifiers: KeyboardModifiers = [], instance: Int = 0)
    /// CGEvent left-click on an element (bypasses AXPress, uses real mouse click).
    /// Use for selecting items in SwiftUI List/OutlineGroup.
    case macCGClick(titled: String, instance: Int = 0)
    /// CGEvent left-click on an element matching the query (bypasses AXPress,
    /// uses real mouse click). Use when targeting elements by accessibility
    /// identifier — e.g., individual terminal panes — instead of fragile
    /// hard-coded screen coordinates.
    ///
    /// `pointInRect` maps the matched element's frame to the actual click
    /// point. Defaults to the centre. Override when the matched element
    /// wraps a smaller click target (e.g. macOS sidebar `List` collapses
    /// section header contents into one AXHeading element, hiding the inner
    /// "+" Button — `pointInRect: { CGPoint(x: $0.maxX - 8, y: $0.midY) }`
    /// targets the right edge where the button lives).
    case macCGClickElement(
        query: ElementQuery,
        pointInRect: @Sendable (CGRect) -> CGPoint = { CGPoint(x: $0.midX, y: $0.midY) },
        instance: Int = 0
    )
    /// Right-click an element to open its context menu
    case macRightClick(titled: String, instance: Int = 0)
    /// Right-click an element and then click a menu item from the context menu
    case macContextMenuClick(elementTitle: String, menuItem: String, instance: Int = 0)
    /// Right-click an element, expand a submenu by pressing its parent label,
    /// and then click an item inside that submenu. Used for nested context
    /// menus (e.g. the session row's "Set Color" submenu).
    case macContextSubmenuClick(
        elementTitle: String,
        parentMenuItem: String,
        submenuItem: String,
        instance: Int = 0
    )
    /// Trigger unpair on the first paired viewer via test HTTP endpoint
    case macUnpair(instance: Int = 0)
    /// Update the macOS app's `VersionCompatibility` overrides at runtime and kick
    /// a reconnect. `nil` clears the override; a non-nil value replaces it. Used
    /// by version-mismatch scenarios to simulate an in-place "app update".
    case macSetAppVersion(
        appVersion: String?, minRequiredPartnerVersion: String?, instance: Int = 0
    )
    /// Read the clipboard and store in context
    case macReadClipboard(storeAs: String, instance: Int = 0)
    /// Write text to the system clipboard. Useful for entering characters
    /// AppleScript keystroke can't handle (e.g. emoji) before triggering a
    /// `macPaste` into a focused field.
    case macWriteClipboard(text: String, instance: Int = 0)
    /// Place image bytes on the file-backed clipboard for the given app
    /// instance, simulating "user copied an image to the clipboard". The data
    /// is provided as base-64 so scenarios can stay declarative.
    case macWriteClipboardImage(base64: String, format: String, instance: Int = 0)
    /// Read image bytes off the file-backed clipboard for the given app
    /// instance and store them as base-64 in the execution context. Empty
    /// string when no image is present.
    case macReadClipboardImage(storeAs: String, instance: Int = 0)
    /// Clear both text and image entries on the file-backed clipboard for the
    /// given app instance. Use to wipe stale state between scenarios.
    case macClearClipboard(instance: Int = 0)
    /// Press Cmd+V in the macOS app, pasting the current system clipboard
    /// contents into the focused field.
    case macPaste(instance: Int = 0)
    /// Simulate a Finder file drop onto the terminal view for a specific
    /// pane. Drives the same code path as a real drop (registered drag
    /// types, `performDragOperation`) without going through AppKit's
    /// dragging machinery, which can't easily be triggered from outside
    /// the app process. `paneId` is the tmux pane id (e.g. "%0"); `paths`
    /// is the list of POSIX paths to drop. `${var}` interpolation is
    /// supported in both fields.
    case macDropFilesOnPane(paneId: String, paths: [String], instance: Int = 0)
    /// Wait for a text element to appear in the macOS app's accessibility tree
    case macWaitForElement(titled: String, timeout: TimeInterval = 10, instance: Int = 0)
    /// Wait for a text element to disappear from the macOS app's accessibility tree
    case macWaitForElementToDisappear(titled: String, timeout: TimeInterval = 10, instance: Int = 0)
    /// Wait for an element matching an ElementQuery to appear in the macOS app's accessibility tree
    case macWaitForElementQuery(ElementQuery, timeout: TimeInterval = 10, instance: Int = 0)
    /// Wait for an element matching an ElementQuery to disappear from the macOS app's accessibility tree
    case macWaitForElementQueryToDisappear(ElementQuery, timeout: TimeInterval = 10, instance: Int = 0)
    /// Open the Panes window via the status item menu
    case macOpenPanesWindow(instance: Int = 0)
    /// Move the macOS app window to a screen position
    case macMoveWindow(x: Int, y: Int, instance: Int = 0)
    /// Resize the macOS app window
    case macResizeWindow(width: Int, height: Int, instance: Int = 0)
    /// Set the sidebar width of the NavigationSplitView
    case macSetSidebarWidth(_ width: Int, instance: Int = 0)
    /// Focus a text field by title so subsequent typing goes into it
    case macFocusElement(titled: String, instance: Int = 0)
    /// Type text into the macOS app (via AppleScript keystroke).
    /// Set `charDelay` > 0 to type character-by-character with delays (for remote terminals).
    case macType(text: String, pressReturn: Bool = false, charDelay: TimeInterval = 0, instance: Int = 0)
    /// Scroll the macOS terminal view up by the given number of pages (Page Up key)
    case macScrollUp(pages: Int = 1, instance: Int = 0)
    /// Send scroll wheel events to the macOS app window via CGEvent.
    /// `deltaY` > 0 scrolls up, < 0 scrolls down. `count` is how many events to send.
    case macScrollWheel(deltaY: Int32, count: Int = 3, instance: Int = 0)
    /// Click at a specific screen coordinate in the macOS app.
    case macClickAtPoint(x: Double, y: Double, instance: Int = 0)
    /// Drag from one screen coordinate to another in the macOS app.
    case macDrag(fromX: Double, fromY: Double, toX: Double, toY: Double, instance: Int = 0)
    /// Drag from the center of one accessibility element to the center of
    /// another. Resolves both queries against the running app before posting
    /// CGEvent drag events, so scenarios don't have to compute screen
    /// coordinates by hand to test SwiftUI drag-and-drop (e.g. tab reorder).
    case macDragElement(from: ElementQuery, to: ElementQuery, instance: Int = 0)
    /// Take a macOS screenshot, optionally comparing against a stored baseline
    /// Default tolerance of 2% because sometimes the image needs to be normalized
    /// and in this case some pixels will differ.
    case macScreenshot(label: String, compare: Bool = true, tolerance: Double = 2, perPixelThreshold: Double = 0.02, instance: Int = 0)

    // MARK: - Tmux

    /// Create a tmux session on the test socket
    case tmuxCreateSession(name: String, width: Int, height: Int)
    /// Query pane dimensions and store them in the execution context
    case tmuxStorePaneDimensions(target: String, widthKey: String, heightKey: String)
    /// Query the tmux pane ID (e.g. "%0") for a target and store it in the execution context
    case tmuxStorePaneId(target: String, storeAs: String)
    /// Capture the visible content of a tmux pane and store it in the execution context
    case tmuxCapturePaneContent(target: String, storeAs: String)
    /// Send keys to a tmux pane on the test socket (bypasses macOS app input path)
    case tmuxSendKeys(target: String, keys: String, literal: Bool = false)
    /// Run an arbitrary tmux command on the test socket (e.g., "split-window -h -t session:0")
    case tmuxCommand(arguments: [String])
    /// Query a tmux format string via `display-message -p` and store the output in context.
    case tmuxStoreDisplayMessage(target: String, format: String, storeAs: String)
    /// Poll a tmux format string via `display-message -p` until the result contains a substring.
    case waitForTmuxDisplayMessage(
        target: String, format: String, contains: String, timeout: TimeInterval = 20
    )
    /// Poll a tmux format string via `display-message -p` until the trimmed result
    /// differs from `notEqualTo`. Use this when waiting for a value to change away
    /// from a known stale value (e.g. a pane width that should grow after a layout
    /// change) but the exact target value is not known in advance.
    case waitForTmuxDisplayMessageNotEqual(
        target: String, format: String, notEqualTo: String, timeout: TimeInterval = 20
    )

    // MARK: - Hook Events

    /// Deliver a hook event to the macOS app by writing one length-prefixed
    /// `IngressFrame` to the app's ingress socket (spec §8) — the transport that
    /// replaced the deleted HTTP hook POST path.
    ///
    /// - `pluginID` routes the frame to the owning core. Defaults to
    ///   `"claude-code"` so existing scenarios sending real Claude hook JSON keep
    ///   exercising the real `ClaudeCodePluginCore.handleIngress` translation —
    ///   same flow, new transport. Codex scenarios pass `"codex"`; the
    ///   `EchoPluginCore` round-trip scenarios pass `"echo"`.
    /// - `json` is the raw host-agent event body the core decodes (supports
    ///   `${var}` interpolation).
    /// - `tmuxPane` becomes the frame's `context["TMUX_PANE"]` (pane identity);
    ///   `projectPath`, when present, becomes `context["CLAUDE_PROJECT_DIR"]`.
    /// - The socket path is the per-scenario `<gallager-state-root>/ingress.sock`,
    ///   derived per instance by the orchestrator.
    case macSendHookEvent(
        pluginID: String = "claude-code",
        json: String,
        tmuxPane: String,
        projectPath: String? = nil,
        instance: Int = 0
    )

    // MARK: - Assertions

    /// Assert two stored context values are equal
    case assertStoredEqual(key: String, otherKey: String)
    /// Assert two stored context values are NOT equal
    case assertStoredNotEqual(key: String, otherKey: String)
    /// Assert a stored context value contains a substring
    case assertStoredContains(key: String, substring: String)
    /// Assert a stored context value does NOT contain a substring
    case assertStoredNotContains(key: String, substring: String)

    // MARK: - Scripts

    /// Copy a bundled script from the `Scripts` resource directory to `$TMPDIR`.
    /// The script is automatically removed when the scenario ends, even on failure.
    /// Reference the script in tmux commands as `$TMPDIR/<name>`.
    case injectScript(name: String)

    // MARK: - General

    /// Wait for a duration
    case wait(seconds: TimeInterval)
    /// Store a literal value in the execution context
    case storeValue(key: String, value: String)
    /// Read a file's contents and store in the execution context (supports `${var}` interpolation in path)
    case readFile(path: String, storeAs: String)
    /// Delete a file at the given path (no-op if it doesn't exist). Used between
    /// phases to clear an append-only fixture log so subsequent
    /// `waitForFileContains` assertions don't pass on stale entries from earlier
    /// phases. Path supports `${var}` interpolation.
    case removeFile(path: String)
    /// Poll a file until it contains a substring, then store its contents (supports `${var}` interpolation)
    case waitForFileContains(
        path: String, substring: String, storeAs: String, timeout: TimeInterval = 20, pollInterval: TimeInterval = 1
    )
    /// Log a message
    case log(String)
}
