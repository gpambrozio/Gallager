import AppKit
import CoreGraphics
import Foundation
import Logging

/// Drives the macOS Gallager app via external Accessibility APIs, CGEvent, and AppleScript.
///
/// Tracks the launched app instance by PID so E2E tests can run alongside a
/// production copy of the same app without interfering with it.
public actor MacOSDriver {
    private let processRunner = ProcessRunner()
    private let logger: Logger

    private var appPath: String?
    private let appName = "Gallager"
    /// PID of the app instance launched by `launchApp`. Used to scope termination,
    /// AppleScript interactions, and window lookup to the test instance only.
    private var appPID: pid_t?

    /// Default port for the in-app TestAccessibilityServer HTTP endpoint.
    public static let defaultTestAccessibilityPort: UInt16 = 18_081

    /// Port for the in-app TestAccessibilityServer HTTP endpoint.
    let testAccessibilityPort: UInt16

    public init(label: String = "e2e.macos-driver", testAccessibilityPort: UInt16 = MacOSDriver.defaultTestAccessibilityPort) {
        self.logger = Logger(label: label)
        self.testAccessibilityPort = testAccessibilityPort
    }

    /// Whether the app instance launched by `launchApp` is still running.
    /// Used by the orchestrator to decide whether to attempt failure screenshots.
    public var isLaunched: Bool {
        guard let pid = appPID else { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return !app.isTerminated
        }
        return false
    }

    // MARK: - App Lifecycle

    /// Launch the macOS app and record its PID for targeted interaction
    public func launchApp(path: String, arguments: [String] = []) async throws {
        logger.info("Launching macOS app: \(path)")
        appPath = path

        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        // Pin the app's TMPDIR to the test runner's temp dir so tmux panes the app
        // creates (e.g. via "New Terminal" → TmuxService) resolve `$TMPDIR/<script>`
        // to where `injectScript` copies — otherwise scripts run in app-created
        // panes are "not found" (the app inherits a different sandbox temp dir).
        configuration.environment = ["LOG_LEVEL": "debug", "TMPDIR": NSTemporaryDirectory()]

        let runningApp = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        appPID = runningApp.processIdentifier
        logger.info("macOS app launched with PID \(runningApp.processIdentifier)")

        // Wait for the app to launch
        try await Task.sleep(for: .seconds(2))
    }

    /// Terminate the test macOS app instance by PID.
    /// Only terminates the instance that was launched by `launchApp`, leaving
    /// any production copy of the app running.
    public func terminateApp() async throws {
        guard let pid = appPID else {
            logger.warning("No app PID recorded — skipping termination")
            return
        }
        logger.info("Terminating macOS app (PID \(pid))")

        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            app.terminate()
            // Wait for the process to exit
            let deadline = Date().addingTimeInterval(5)
            while !app.isTerminated, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            if !app.isTerminated {
                logger.warning("App did not terminate gracefully, force-killing PID \(pid)")
                app.forceTerminate()
                try await Task.sleep(for: .milliseconds(500))
            }
        } else {
            logger.info("App PID \(pid) already terminated or no longer valid")
        }
        appPID = nil
    }

    // MARK: - App Activation

    /// Bring the app to the front and make its key window active.
    /// Uses `NSRunningApplication.activate` via AppleScript so the app
    /// passes both `NSApp.isActive` and `window.isKeyWindow` checks.
    public func activate() async throws {
        let pid = try requirePID()
        logger.info("Activating app (pid \(pid))")
        let script = """
        tell application "System Events"
            tell (first process whose unix id is \(pid))
                set frontmost to true
            end tell
        end tell
        delay 0.3
        """
        try await runAppleScript(script)
    }

    // MARK: - Settings Navigation

    /// Open the Settings window via the status item menu
    public func openSettings() async throws {
        logger.info("Opening Settings via status item menu")
        let script = try """
        tell application "System Events"
            tell (first process whose unix id is \(requirePID()))
                click menu bar item 1 of menu bar 2
                delay 0.5
                click menu item "Settings..." of menu 1 of menu bar item 1 of menu bar 2
            end tell
        end tell
        delay 1
        """
        try await runAppleScript(script)
    }

    /// Wait for a window to appear via the external Accessibility API.
    public func waitForWindow(titled: String, timeout: TimeInterval = 5) async throws {
        let pid = try requirePID()
        try await Polling.waitUntil(
            description: "window titled \"\(titled)\"",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.windowExists(appPID: pid, titled: titled)
        }
    }

    /// Wait for a top-level window whose title equals `title` exactly.
    /// Asserts on `navigationTitle` without substring ambiguity.
    public func waitForWindowTitle(equals title: String, timeout: TimeInterval = 5) async throws {
        let pid = try requirePID()
        try await Polling.waitUntil(
            description: "window with title equal to \"\(title)\"",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.windowExists(appPID: pid, titledExactly: title)
        }
    }

    /// Select a tab in the Settings window by clicking it via AX.
    public func selectSettingsTab(_ tabName: String) async throws {
        let pid = try requirePID()
        logger.info("Selecting settings tab: \(tabName)")
        try await waitForAXElement(pid: pid, titled: tabName, timeout: 5)
        if !MacOSAccessibility.press(appPID: pid, titled: tabName) {
            throw MacOSDriverError.elementNotFound(tabName)
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Click a button by title or help text via AX.
    /// Tries multiple AX matches and walks parent chain; falls back to CGEvent click.
    public func clickButton(titled: String) async throws {
        let pid = try requirePID()
        logger.info("Clicking button: \(titled)")
        try await waitForAXElement(pid: pid, titled: titled, timeout: 5)
        if !MacOSAccessibility.press(appPID: pid, titled: titled) {
            throw MacOSDriverError.elementNotFound(titled)
        }
    }

    /// Click a menu trigger button then click a menu item via AX.
    /// AX can see NSMenu popup items as AXMenu > AXMenuItem in the tree.
    public func clickMenuItem(menuButtonTitle: String, itemTitle: String) async throws {
        let pid = try requirePID()
        logger.info("Clicking menu '\(menuButtonTitle)' → '\(itemTitle)'")

        // Step 1: Click the menu trigger via AX (opens the popup)
        try await waitForAXElement(pid: pid, titled: menuButtonTitle, timeout: 5)
        if !MacOSAccessibility.press(appPID: pid, titled: menuButtonTitle) {
            throw MacOSDriverError.elementNotFound(menuButtonTitle)
        }

        // Step 2: Poll for the menu item (popup needs time to appear and populate)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            if MacOSAccessibility.press(appPID: pid, titled: itemTitle) {
                return
            }
        }

        throw MacOSDriverError.elementNotFound("\(menuButtonTitle) → \(itemTitle)")
    }

    // MARK: - Key Press

    /// Press a key with optional modifiers via CGEvent.
    ///
    /// Resolves named keys (Tab, Escape, …) and character keys (letters,
    /// digits, common punctuation) into US-keyboard virtual key codes, then
    /// posts a keyDown/keyUp pair through `CGEvent`. The app is focused
    /// first so the event lands in the right process.
    public func pressKey(_ key: Key, modifiers: KeyboardModifiers = []) async throws {
        let pid = try requirePID()
        // Named keys always resolve; only `.character(_)` cases with an
        // unsupported symbol can fail to map.
        guard let virtualKey = MacOSAccessibility.virtualKeyCode(for: key) else {
            let desc: String
            if case let .character(character) = key {
                desc = String(character)
            } else {
                desc = String(describing: key)
            }
            throw MacOSDriverError.unsupportedShortcutKey(desc)
        }
        logger.info("Pressing key '\(modifiers)+\(key)' (PID \(pid))")
        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))
        MacOSAccessibility.pressKey(code: virtualKey, modifiers: modifiers.cgEventFlags)
        try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - CGEvent Click

    /// CGEvent left-click on an element (bypasses AXPress, uses real mouse click).
    /// Use for selecting items in SwiftUI List/OutlineGroup.
    public func cgClick(titled: String) async throws {
        let pid = try requirePID()
        logger.info("CGEvent clicking: \(titled)")
        try await waitForAXElement(pid: pid, titled: titled, timeout: 5)
        if !MacOSAccessibility.cgClick(appPID: pid, titled: titled) {
            throw MacOSDriverError.elementNotFound(titled)
        }
    }

    /// CGEvent left-click on an element matching the query. Use to target
    /// elements by accessibility identifier (e.g. an individual terminal pane
    /// via `.identifier("terminal-%1")`) instead of brittle hard-coded screen
    /// coordinates.
    ///
    /// `pointInRect` maps the matched element's frame to the actual click
    /// point. Defaults to the centre; override to target a corner or edge
    /// when the matched element is a wider container.
    public func cgClick(
        matching query: ElementQuery,
        pointInRect: @Sendable (CGRect) -> CGPoint = { CGPoint(x: $0.midX, y: $0.midY) }
    ) async throws {
        let pid = try requirePID()
        logger.info("CGEvent clicking element matching query")
        _ = try await Polling.waitFor(
            description: "macOS UI element for cg-click",
            timeout: 5,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.findElement(appPID: pid, matching: query)
        }
        if !MacOSAccessibility.cgClick(appPID: pid, matching: query, pointInRect: pointInRect) {
            throw MacOSDriverError.elementNotFound("query for cg-click")
        }
    }

    // MARK: - Right-Click / Context Menu

    /// Right-click on an element to open its context menu.
    public func rightClick(titled: String) async throws {
        let pid = try requirePID()
        logger.info("Right-clicking: \(titled)")
        try await waitForAXElement(pid: pid, titled: titled, timeout: 5)
        if !MacOSAccessibility.rightClick(appPID: pid, titled: titled) {
            throw MacOSDriverError.elementNotFound(titled)
        }
    }

    /// Right-click on an element matching a query to open its context menu.
    public func rightClick(matching query: ElementQuery) async throws {
        let pid = try requirePID()
        logger.info("Right-clicking element matching query")
        _ = try await Polling.waitFor(
            description: "macOS UI element for right-click",
            timeout: 5,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.findElement(appPID: pid, matching: query)
        }
        if !MacOSAccessibility.rightClick(appPID: pid, matching: query) {
            throw MacOSDriverError.elementNotFound("query for right-click")
        }
    }

    /// Right-click on an element to open its context menu, then click a menu item.
    /// Combines right-click with polling for the context menu item to appear.
    public func contextMenuClick(elementTitle: String, menuItem: String) async throws {
        let pid = try requirePID()
        logger.info("Context menu click: '\(elementTitle)' → '\(menuItem)'")

        // Step 1: Right-click to open context menu
        try await waitForAXElement(pid: pid, titled: elementTitle, timeout: 5)
        if !MacOSAccessibility.rightClick(appPID: pid, titled: elementTitle) {
            throw MacOSDriverError.elementNotFound(elementTitle)
        }

        // Step 2: Poll for the menu item (context menu needs time to appear)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            if MacOSAccessibility.press(appPID: pid, titled: menuItem) {
                return
            }
        }

        throw MacOSDriverError.elementNotFound("\(elementTitle) context menu → \(menuItem)")
    }

    /// Right-click an element, expand a submenu by pressing its parent label,
    /// then click an item inside that submenu. Used for nested SwiftUI `Menu`
    /// items inside a `.contextMenu { }` (e.g. the session row's "Set Color"
    /// submenu, whose colour rows only join the AX tree once the parent is
    /// expanded). Pressing the parent menu item opens the submenu without
    /// dismissing the context menu — AppKit treats menu items that own a
    /// submenu as "expand on press" rather than "fire and dismiss".
    public func contextSubmenuClick(
        elementTitle: String,
        parentMenuItem: String,
        submenuItem: String
    ) async throws {
        let pid = try requirePID()
        logger.info(
            "Context submenu click: '\(elementTitle)' → '\(parentMenuItem)' → '\(submenuItem)'"
        )

        // Step 1: Right-click to open the top-level context menu.
        try await waitForAXElement(pid: pid, titled: elementTitle, timeout: 5)
        if !MacOSAccessibility.rightClick(appPID: pid, titled: elementTitle) {
            throw MacOSDriverError.elementNotFound(elementTitle)
        }

        // Step 2: Poll for the parent menu item, then press it to expand the
        // submenu. Pressing a SwiftUI `Menu`'s parent label opens the submenu.
        let parentDeadline = Date().addingTimeInterval(3)
        var parentExpanded = false
        while Date() < parentDeadline {
            try await Task.sleep(for: .milliseconds(300))
            if MacOSAccessibility.press(appPID: pid, titled: parentMenuItem) {
                parentExpanded = true
                break
            }
        }
        guard parentExpanded else {
            throw MacOSDriverError.elementNotFound(
                "\(elementTitle) context menu → \(parentMenuItem)"
            )
        }

        // Step 3: Poll for the submenu item now that the submenu is open.
        let submenuDeadline = Date().addingTimeInterval(3)
        while Date() < submenuDeadline {
            try await Task.sleep(for: .milliseconds(300))
            if MacOSAccessibility.press(appPID: pid, titled: submenuItem) {
                return
            }
        }

        throw MacOSDriverError.elementNotFound(
            "\(elementTitle) context menu → \(parentMenuItem) → \(submenuItem)"
        )
    }

    // MARK: - Panes Window

    /// Open the Panes window via the status item menu
    public func openPanesWindow() async throws {
        logger.info("Opening Panes window via status item menu")
        let script = try """
        tell application "System Events"
            tell (first process whose unix id is \(requirePID()))
                click menu bar item 1 of menu bar 2
                delay 0.5
                click menu item "Show Panes Window" of menu 1 of menu bar item 1 of menu bar 2
            end tell
        end tell
        delay 1
        """
        try await runAppleScript(script)
    }

    /// Move the macOS app window to a screen position via AX.
    public func moveWindow(x: Int, y: Int) async throws {
        let pid = try requirePID()
        logger.info("Moving window to (\(x), \(y))")
        var lastReason = "(no attempt recorded)"
        for attempt in 1...3 {
            let result = MacOSAccessibility.moveWindowDetailed(appPID: pid, x: x, y: y)
            if result.success { return }
            lastReason = result.reason
            logger.info("Move attempt \(attempt)/3 failed: \(lastReason)")
            if attempt < 3 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw MacOSDriverError.appleScriptFailed(
            "Failed to move window to (\(x), \(y)) after 3 attempts — \(lastReason)"
        )
    }

    /// Resize the macOS app window via AX.
    public func resizeWindow(width: Int, height: Int) async throws {
        let pid = try requirePID()
        logger.info("Resizing window to \(width)x\(height)")
        var lastReason = "(no attempt recorded)"
        for attempt in 1...3 {
            let result = MacOSAccessibility.resizeWindowDetailed(appPID: pid, width: width, height: height)
            if result.success { return }
            lastReason = result.reason
            logger.info("Resize attempt \(attempt)/3 failed: \(lastReason)")
            if attempt < 3 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw MacOSDriverError.appleScriptFailed(
            "Failed to resize window to \(width)x\(height) after 3 attempts — \(lastReason)"
        )
    }

    /// Set the sidebar width of the NavigationSplitView via the in-app HTTP server.
    /// NSSplitView.setPosition() requires in-process access, so this still uses HTTP.
    public func setSidebarWidth(_ width: Int) async throws {
        logger.info("Setting sidebar width to \(width)")
        let success = try await MacAppHTTPClient.setSidebarWidth(width, port: testAccessibilityPort)
        if !success {
            throw MacOSDriverError.elementNotFound("NSSplitView for sidebar width")
        }
    }

    /// Focus a text field by title so subsequent typing goes into it.
    public func focusElement(titled: String) async throws {
        let pid = try requirePID()
        logger.info("Focusing element: \(titled)")
        if !MacOSAccessibility.focusElement(appPID: pid, titled: titled) {
            throw MacOSDriverError.elementNotFound(titled)
        }
    }

    /// Write text to the system pasteboard so a subsequent `paste()` (Cmd+V)
    /// inserts it into the focused field. Useful for input AppleScript
    /// keystroke can't deliver — emoji, multi-codepoint glyphs, etc.
    public func writeClipboard(text: String) async throws {
        logger.info("Writing to clipboard: \(text.prefix(30))")
        // `pbcopy` reads stdin and sets the system clipboard. The trailing
        // newline that an `echo` would add is suppressed with `printf %s`.
        let result = try await processRunner.run(
            "/bin/sh",
            arguments: ["-c", "printf %s \"$1\" | /usr/bin/pbcopy", "sh", text]
        )
        guard result.isSuccess else {
            throw MacOSDriverError.appleScriptFailed(
                "pbcopy failed: \(result.stderrString)"
            )
        }
    }

    /// Press Cmd+V in the macOS app, pasting the current clipboard contents
    /// into the focused field. Pairs with `writeClipboard(text:)` to enter
    /// characters AppleScript keystroke can't type directly.
    public func paste() async throws {
        let pid = try requirePID()
        logger.info("Pasting via Cmd+V")
        let script = """
        tell application "System Events"
            tell (first process whose unix id is \(pid))
                set frontmost to true
                delay 0.1
                keystroke "v" using command down
            end tell
        end tell
        """
        try await runAppleScript(script)
    }

    /// Type text into the macOS app via AppleScript keystroke.
    /// - Parameters:
    ///   - charDelay: Seconds to wait between each character (0 = type all at once).
    ///     Useful for remote terminals where keystrokes travel through a relay.
    public func type(text: String, pressReturn: Bool, charDelay: TimeInterval = 0) async throws {
        logger.info("Typing text: \(text.prefix(30))... (pressReturn: \(pressReturn), charDelay: \(charDelay))")
        let pid = try requirePID()
        let returnClause = pressReturn ? """

                delay 0.1
                keystroke return
        """ : ""

        if charDelay > 0 {
            // Type character-by-character with delays for reliable remote input
            var keystrokes = text.map { char -> String in
                let escaped = escapeForAppleScript(String(char))
                return "keystroke \"\(escaped)\"\n                delay \(charDelay)"
            }.joined(separator: "\n                ")
            if pressReturn {
                keystrokes += "\n                delay 0.1\n                keystroke return"
            }
            let script = """
            tell application "System Events"
                tell (first process whose unix id is \(pid))
                    set frontmost to true
                    \(keystrokes)
                end tell
            end tell
            """
            try await runAppleScript(script)
        } else {
            let escaped = escapeForAppleScript(text)
            // A brief delay after activation lets the app's event loop settle
            // so the first keystroke isn't processed in isolation.  Without
            // this, the KeystrokeDebouncer can flush a single-char batch
            // before the remaining characters arrive — producing two WebSocket
            // messages that the host may reorder under contention.
            let script = """
            tell application "System Events"
                tell (first process whose unix id is \(pid))
                    set frontmost to true
                    delay 0.1
                    keystroke "\(escaped)"\(returnClause)
                end tell
            end tell
            """
            try await runAppleScript(script)
        }
    }

    // MARK: - Scroll

    /// Scroll the terminal view up by sending Page Up key events.
    public func scrollUp(pages: Int) async throws {
        logger.info("Scrolling up \(pages) page(s)")
        // Key code 116 = Page Up
        let keyPresses = (0..<pages).map { _ in "key code 116" }.joined(separator: "\n                delay 0.1\n                ")
        let script = try """
        tell application "System Events"
            tell (first process whose unix id is \(requirePID()))
                set frontmost to true
                \(keyPresses)
            end tell
        end tell
        """
        try await runAppleScript(script)
    }

    /// Send scroll wheel events to the center of the app's main window via CGEvent.
    /// - Parameters:
    ///   - deltaY: Scroll amount in lines (positive = up, negative = down)
    ///   - count: Number of individual scroll events to send
    public func scrollWheel(deltaY: Int32, count: Int = 1) async throws {
        let pid = try requirePID()
        logger.info("Scroll wheel: deltaY=\(deltaY), count=\(count)")

        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))

        guard let center = windowCenter(appPID: pid) else {
            throw MacOSDriverError.windowNotFound(appName)
        }

        for _ in 0..<count {
            MacOSAccessibility.scrollWheel(at: center, deltaY: deltaY)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Click at a specific screen coordinate after focusing the app.
    public func clickAtScreenPoint(x: Double, y: Double) async throws {
        let pid = try requirePID()
        logger.info("Click at screen point (\(x), \(y))")

        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))

        MacOSAccessibility.clickAtPoint(CGPoint(x: x, y: y))
    }

    /// Drag from one screen coordinate to another after focusing the app.
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        let pid = try requirePID()
        logger.info("Drag from (\(fromX), \(fromY)) to (\(toX), \(toY))")

        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))

        MacOSAccessibility.drag(
            from: CGPoint(x: fromX, y: fromY),
            to: CGPoint(x: toX, y: toY)
        )
    }

    /// Drag from the center of one accessibility element to the center of
    /// another. Used by scenarios that test SwiftUI drag-and-drop (e.g. tab
    /// strip reorder) so the source and target points stay anchored to the
    /// elements themselves instead of fragile screen coordinates.
    public func dragElement(from fromQuery: ElementQuery, to toQuery: ElementQuery) async throws {
        let pid = try requirePID()
        logger.info("Drag element \(fromQuery) → \(toQuery)")
        if !MacOSAccessibility.dragElement(appPID: pid, from: fromQuery, to: toQuery) {
            throw MacOSDriverError.elementNotFound("\(fromQuery) or \(toQuery)")
        }
    }

    /// Get the center point of the app's first visible window.
    private func windowCenter(appPID: pid_t) -> CGPoint? {
        let allWindows = MacOSAccessibility.windows(appPID: appPID)
        guard let window = allWindows.first else { return nil }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(
            window.element, kAXPositionAttribute as CFString, &positionValue
        )
        let sizeResult = AXUIElementCopyAttributeValue(
            window.element, kAXSizeAttribute as CFString, &sizeValue
        )
        guard posResult == .success, sizeResult == .success else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    // MARK: - Unpair

    /// Trigger unpair via the macOS app's test HTTP endpoint.
    /// Uses HTTP because it posts a NotificationCenter notification that the app observes.
    public func unpair() async throws {
        logger.info("Triggering unpair via HTTP endpoint")
        let success = try await MacAppHTTPClient.unpair(port: testAccessibilityPort)
        if !success {
            throw MacOSDriverError.elementNotFound("unpair endpoint returned failure")
        }
    }

    // MARK: - Version Override

    /// Update the app's `VersionCompatibility` overrides at runtime and kick a
    /// reconnect. `nil` clears the override (so the app reports its bundle version
    /// / default minimum); a non-nil value sets the override to that string.
    public func setAppVersion(appVersion: String?, minRequiredPartnerVersion: String?) async throws {
        logger.info(
            "Updating Mac version overrides: app=\(appVersion ?? "<clear>") min=\(minRequiredPartnerVersion ?? "<clear>")"
        )
        let success = try await MacAppHTTPClient.setAppVersion(
            appVersion: appVersion,
            minRequiredPartnerVersion: minRequiredPartnerVersion,
            port: testAccessibilityPort
        )
        if !success {
            throw MacOSDriverError.elementNotFound("reconnect endpoint returned failure")
        }
    }

    // MARK: - File Drop Simulation

    /// Trigger a simulated Finder file drop on the given tmux pane via the
    /// in-process `/drop-files` test endpoint. Drives the same code path as
    /// a real drop on `InteractiveTerminalView`.
    public func dropFilesOnPane(paneId: String, paths: [String]) async throws {
        logger.info("Simulating file drop on pane \(paneId): \(paths)")
        let success = try await MacAppHTTPClient.dropFilesOnPane(
            paneId: paneId,
            paths: paths,
            port: testAccessibilityPort
        )
        if !success {
            throw MacOSDriverError.elementNotFound(
                "drop-files endpoint failed for pane \(paneId)"
            )
        }
    }

    // MARK: - Hook Events (ingress socket)

    /// Deliver a hook event to the macOS app by writing one length-prefixed
    /// `IngressFrame` to the app's ingress socket (spec §8) — the transport that
    /// replaced the deleted HTTP `HookServerService` path.
    ///
    /// `pluginID` routes the frame to the owning core (`"claude-code"` /
    /// `"codex"` / `"echo"`); `json` is the raw host-agent event the core
    /// decodes; `tmuxPane`/`projectPath` become the harvested ingress `context`
    /// (`TMUX_PANE` / `CLAUDE_PROJECT_DIR`). `socketPath` is the per-scenario
    /// `<gallager-state-root>/ingress.sock`.
    public func sendHookEvent(
        pluginID: String,
        json: String,
        tmuxPane: String,
        projectPath: String?,
        socketPath: String
    ) async throws {
        logger.info("Sending ingress frame (plugin_id=\(pluginID)) for pane: \(tmuxPane)")
        var context = ["TMUX_PANE": tmuxPane]
        if let projectPath {
            context["CLAUDE_PROJECT_DIR"] = projectPath
        }
        do {
            _ = try await IngressSocketClient.sendFrame(
                pluginID: pluginID,
                context: context,
                payload: Data(json.utf8),
                socketPath: socketPath
            )
        } catch {
            throw MacOSDriverError.hookEventFailed(
                "Ingress frame write failed: \(error.localizedDescription)"
            )
        }
        logger.info("Ingress frame written successfully")
    }

    // MARK: - Wait for Element

    /// Close a window by title via its AXCloseButton.
    public func closeWindow(titled: String) async throws {
        let pid = try requirePID()
        logger.info("Closing window: \(titled)")
        if !MacOSAccessibility.closeWindow(appPID: pid, titled: titled) {
            throw MacOSDriverError.windowNotFound(titled)
        }
    }

    /// Wait for an element with the given title to appear in the macOS app
    public func waitForElement(titled: String, timeout: TimeInterval = 10) async throws {
        let pid = try requirePID()
        try await waitForAXElement(pid: pid, titled: titled, timeout: timeout)
    }

    /// Wait for an element to disappear from the macOS app's accessibility tree
    public func waitForElementToDisappear(titled: String, timeout: TimeInterval = 10) async throws {
        let pid = try requirePID()
        try await Polling.waitUntil(
            description: "macOS UI element '\(titled)' to disappear",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.findElement(appPID: pid, titled: titled) == nil
        }
    }

    /// Wait for an element matching an ElementQuery to appear in the macOS app
    @discardableResult
    public func waitForElement(matching query: ElementQuery, timeout: TimeInterval = 10) async throws -> UIElement {
        let pid = try requirePID()
        do {
            return try await Polling.waitFor(
                description: "macOS UI element matching \(query)",
                timeout: timeout,
                pollInterval: 0.25
            ) {
                MacOSAccessibility.findElement(appPID: pid, matching: query)
            }
        } catch {
            // One-shot diagnostic on timeout — explains what matched vs. what didn't.
            // Include the diagnostic in the thrown error so it surfaces in the JSON
            // report (step errors use `.localizedDescription`). The swift logger
            // output is easy to miss in CI noise.
            let diag = MacOSAccessibility.diagnoseQuery(appPID: pid, query: query)
            logger.warning("AX diagnostic for \(query):\n\(diag)")
            throw MacOSDriverError.elementQueryTimedOut(query: "\(query)", diagnostic: diag)
        }
    }

    /// Wait for an element matching an ElementQuery to disappear from the macOS app
    public func waitForElementToDisappear(matching query: ElementQuery, timeout: TimeInterval = 10) async throws {
        let pid = try requirePID()
        try await Polling.waitUntil(
            description: "macOS UI element matching \(query) to disappear",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.findElement(appPID: pid, matching: query) == nil
        }
    }

    // MARK: - Screenshots

    /// Take a screenshot of the macOS app window
    public func screenshot(output: String) async throws {
        logger.info("Taking macOS screenshot: \(output)")

        guard let pid = appPID else {
            throw MacOSDriverError.windowNotFound(appName)
        }

        // Ensure the app is focused so the window chrome renders
        // consistently (active title bar, focused controls, etc.)
        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))

        guard let windowID = getWindowID() else {
            throw MacOSDriverError.windowNotFound(appName)
        }

        _ = try await processRunner.runOrThrow(
            "/usr/sbin/screencapture",
            arguments: ["-x", "-l", "\(windowID)", output]
        )

        // Normalize retina screenshots to 1x so pixel dimensions are
        // consistent regardless of which monitor the window is on.
        try await normalizeScreenshotDPI(path: output)
    }

    // MARK: - Private: AX Element Polling

    /// Wait for an element to appear in the AX tree
    @discardableResult
    private func waitForAXElement(
        pid: pid_t,
        titled: String,
        timeout: TimeInterval
    ) async throws -> UIElement {
        try await Polling.waitFor(
            description: "macOS UI element '\(titled)'",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            MacOSAccessibility.findElement(appPID: pid, titled: titled)
        }
    }

    // MARK: - Private: Screenshot Normalization

    /// Resample a retina (144 DPI) screenshot down to 1x (72 DPI) so pixel
    /// dimensions stay consistent regardless of the display's scale factor.
    private func normalizeScreenshotDPI(path: String) async throws {
        let result = try await processRunner.runOrThrow(
            "/usr/bin/sips",
            arguments: ["-g", "dpiWidth", "-g", "pixelWidth", "-g", "pixelHeight", path]
        )

        let output = result.stdoutString
        func parseValue(_ key: String) -> Double? {
            guard let range = output.range(of: "\(key): ") else { return nil }
            let rest = output[range.upperBound...]
            let valueStr = rest.prefix(while: { $0 != "\n" })
                .trimmingCharacters(in: .whitespaces)
            return Double(valueStr)
        }

        guard
            let dpi = parseValue("dpiWidth"), dpi > 72,
            let width = parseValue("pixelWidth"),
            let height = parseValue("pixelHeight") else {
            return
        }

        let scale = dpi / 72
        let newWidth = Int(width / scale)
        let newHeight = Int(height / scale)

        _ = try await processRunner.runOrThrow(
            "/usr/bin/sips",
            arguments: [
                "-z", "\(newHeight)", "\(newWidth)",
                "-s", "dpiWidth", "72",
                "-s", "dpiHeight", "72",
                path,
            ]
        )

        logger.info("Normalized screenshot from \(Int(width))x\(Int(height)) @\(Int(dpi))dpi to \(newWidth)x\(newHeight) @72dpi")
    }

    // MARK: - Private: CGWindowList

    /// Finds the CGWindowID for the main on-screen window owned by the test app instance (by PID).
    /// Skips tiny windows (tooltips, menu bar items) by requiring a minimum size.
    private func getWindowID() -> CGWindowID? {
        guard let pid = appPID else { return nil }
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
            return nil
        }

        let minimumDimension: CGFloat = 200

        for window in windowList {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == pid,
                let windowNumber = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            // Skip tiny windows like tooltips and menu bar items
            if
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], let height = bounds["Height"],
                width < minimumDimension || height < minimumDimension {
                continue
            }

            return windowNumber
        }
        return nil
    }

    // MARK: - Private: PID Helper

    private func requirePID() throws -> pid_t {
        guard let pid = appPID else {
            throw MacOSDriverError.appNotRunning
        }
        return pid
    }

    // MARK: - Private: AppleScript Helpers

    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private func runAppleScript(_ source: String) async throws -> String {
        try await runAppleScriptReturning(source)
    }

    private func runAppleScriptReturning(_ source: String) async throws -> String {
        let result = try await processRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", source]
        )
        if !result.isSuccess {
            let message = result.stderrString.isEmpty ? "Unknown osascript error" : result.stderrString
            throw MacOSDriverError.appleScriptFailed(message)
        }
        return result.stdoutString
    }
}

/// Errors specific to the macOS driver
public enum MacOSDriverError: Error, LocalizedError {
    case appNotRunning
    case appleScriptFailed(String)
    case windowNotFound(String)
    case elementNotFound(String)
    case hookEventFailed(String)
    case elementQueryTimedOut(query: String, diagnostic: String)
    case unsupportedShortcutKey(String)

    public var errorDescription: String? {
        switch self {
        case .appNotRunning:
            "macOS app is not running"
        case let .appleScriptFailed(message):
            "AppleScript failed: \(message)"
        case let .windowNotFound(title):
            "Window not found: \(title)"
        case let .elementNotFound(title):
            "Element not found for click: \(title)"
        case let .hookEventFailed(message):
            "Hook event failed: \(message)"
        case let .elementQueryTimedOut(query, diagnostic):
            "Timed out waiting for: macOS UI element matching \(query)\nAX diagnostic:\n\(diagnostic)"
        case let .unsupportedShortcutKey(key):
            "Unsupported keyboard shortcut key: \(key)"
        }
    }
}
