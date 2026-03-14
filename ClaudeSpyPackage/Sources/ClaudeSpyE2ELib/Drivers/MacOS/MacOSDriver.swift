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

    // MARK: - App Lifecycle

    /// Launch the macOS app and record its PID for targeted interaction
    public func launchApp(path: String, arguments: [String] = []) async throws {
        logger.info("Launching macOS app: \(path)")
        appPath = path

        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.environment = ["LOG_LEVEL": "debug"]

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

    /// Press Tab key via CGEvent to cycle focus between elements in dialogs.
    public func pressTab() async throws {
        let pid = try requirePID()
        logger.info("Pressing Tab key (PID \(pid))")
        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))
        MacOSAccessibility.pressKey(code: 48) // Tab
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Press Cmd+A to select all text in the focused field.
    public func selectAll() async throws {
        let pid = try requirePID()
        logger.info("Pressing Cmd+A (PID \(pid))")
        MacOSAccessibility.focusApp(appPID: pid)
        try await Task.sleep(for: .milliseconds(200))
        MacOSAccessibility.selectAll()
        try await Task.sleep(for: .milliseconds(200))
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
        if !MacOSAccessibility.moveWindow(appPID: pid, x: x, y: y) {
            throw MacOSDriverError.appleScriptFailed(
                "Failed to move window to (\(x), \(y)) — no visible window found"
            )
        }
    }

    /// Resize the macOS app window via AX.
    public func resizeWindow(width: Int, height: Int) async throws {
        let pid = try requirePID()
        logger.info("Resizing window to \(width)x\(height)")
        if !MacOSAccessibility.resizeWindow(appPID: pid, width: width, height: height) {
            throw MacOSDriverError.appleScriptFailed(
                "Failed to resize window to \(width)x\(height) — no visible window found"
            )
        }
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
            let script = """
            tell application "System Events"
                tell (first process whose unix id is \(pid))
                    set frontmost to true
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

    // MARK: - Hook Events

    /// Send a hook event to the macOS app's real hook server (`/api/hooks`).
    /// The hook server port is read from `hookPortFile` (defaults to `~/.claudespy-port`).
    public func sendHookEvent(json: String, tmuxPane: String, projectPath: String?, hookPortFile: String? = nil) async throws {
        logger.info("Sending hook event via test server, pane: \(tmuxPane)")
        let success = try await MacAppHTTPClient.sendHook(
            json: json,
            tmuxPane: tmuxPane,
            projectPath: projectPath,
            hookPortFile: hookPortFile
        )
        if !success {
            throw MacOSDriverError.hookEventFailed("Hook event POST failed")
        }
        logger.info("Hook event sent successfully")
    }

    // MARK: - Wait for Element

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

    // MARK: - Clipboard

    /// Read the system clipboard
    public func readClipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
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

    /// Finds the CGWindowID for the first on-screen window owned by the test app instance (by PID).
    private func getWindowID() -> CGWindowID? {
        guard let pid = appPID else { return nil }
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == pid,
                let windowNumber = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }
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
        }
    }
}
