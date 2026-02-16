import AppKit
import CoreGraphics
import Foundation
import Logging

/// Drives the macOS Gallager app via HTTP accessibility server, CGEvent, and AppleScript.
///
/// Tracks the launched app instance by PID so E2E tests can run alongside a
/// production copy of the same app without interfering with it.
public actor MacOSDriver {
    private let processRunner = ProcessRunner()
    private let logger = Logger(label: "e2e.macos-driver")

    private var appPath: String?
    private let appName = "Gallager"
    /// PID of the app instance launched by `launchApp`. Used to scope termination,
    /// AppleScript interactions, and window lookup to the test instance only.
    private var appPID: pid_t?
    /// Port the test instance's TestAccessibilityServer listens on.
    private let httpPort: UInt16

    public init(httpPort: UInt16 = 18_081) {
        self.httpPort = httpPort
    }

    // MARK: - App Lifecycle

    /// Launch the macOS app and record its PID for targeted interaction
    public func launchApp(path: String, arguments: [String] = []) async throws {
        logger.info("Launching macOS app: \(path)")
        appPath = path

        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
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
        }
        appPID = nil
    }

    // MARK: - Settings Navigation

    /// Open the Settings window via the status item menu
    public func openSettings() async throws {
        logger.info("Opening Settings via status item menu")
        let script = """
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

    /// Wait for a window to appear via the app's HTTP accessibility server.
    /// Uses the in-app endpoint instead of CGWindowList because kCGWindowName
    /// returns nil without Screen Recording permission on macOS 26+.
    public func waitForWindow(titled: String, timeout: TimeInterval = 5) async throws {
        try await Polling.waitUntil(
            description: "window titled \"\(titled)\"",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            await MacAppHTTPClient.windowExists(titled: titled, port: self.httpPort)
        }
    }

    /// Select a tab in the Settings window by clicking it via the app's HTTP server.
    /// The click happens inside the app process, bypassing window z-ordering issues.
    public func selectSettingsTab(_ tabName: String) async throws {
        logger.info("Selecting settings tab: \(tabName)")
        // Wait for the element to appear, then click via HTTP
        _ = try await waitForHTTPElement(titled: tabName, timeout: 5)
        let clicked = try await MacAppHTTPClient.click(titled: tabName, port: httpPort)
        if !clicked {
            throw MacOSDriverError.elementNotFound(tabName)
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Click a button by title or help text via the app's HTTP server.
    public func clickButton(titled: String) async throws {
        logger.info("Clicking button: \(titled)")
        _ = try await waitForHTTPElement(titled: titled, timeout: 5)
        let clicked = try await MacAppHTTPClient.click(titled: titled, port: httpPort)
        if !clicked {
            throw MacOSDriverError.elementNotFound(titled)
        }
    }

    /// Click a menu trigger button then click a menu item.
    /// Uses HTTP clicks: first to open the popup menu, then polls for the item.
    /// SwiftUI Menu popups appear as separate windows that the HTTP server can search.
    public func clickMenuItem(menuButtonTitle: String, itemTitle: String) async throws {
        logger.info("Clicking menu '\(menuButtonTitle)' → '\(itemTitle)'")

        // Step 1: Click the menu trigger via HTTP (opens the popup)
        _ = try await waitForHTTPElement(titled: menuButtonTitle, timeout: 5)
        let clicked = try await MacAppHTTPClient.click(titled: menuButtonTitle, port: httpPort)
        if !clicked {
            throw MacOSDriverError.elementNotFound(menuButtonTitle)
        }

        // Step 2: Poll for the menu item (popup needs time to appear and populate)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            let itemClicked = try await MacAppHTTPClient.click(titled: itemTitle, port: httpPort)
            if itemClicked {
                return
            }
        }

        throw MacOSDriverError.elementNotFound("\(menuButtonTitle) → \(itemTitle)")
    }

    // MARK: - Panes Window

    /// Open the Panes window via the status item menu
    public func openPanesWindow() async throws {
        logger.info("Opening Panes window via status item menu")
        let script = """
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

    /// Resize the macOS app window via the in-app HTTP server.
    /// Uses NSWindow.setFrame instead of AppleScript because MenuBarExtra apps
    /// don't expose windows through System Events.
    public func resizeWindow(width: Int, height: Int) async throws {
        logger.info("Resizing window to \(width)x\(height)")
        let resized = try await MacAppHTTPClient.resizeWindow(width: width, height: height, port: httpPort)
        if !resized {
            throw MacOSDriverError.appleScriptFailed(
                "Failed to resize window to \(width)x\(height) — no visible window found"
            )
        }
    }

    /// Set the sidebar width of the NavigationSplitView via the in-app HTTP server.
    public func setSidebarWidth(_ width: Int) async throws {
        logger.info("Setting sidebar width to \(width)")
        let success = try await MacAppHTTPClient.setSidebarWidth(width, port: httpPort)
        if !success {
            throw MacOSDriverError.elementNotFound("NSSplitView for sidebar width")
        }
    }

    /// Type text into the macOS app via AppleScript keystroke
    public func type(text: String, pressReturn: Bool) async throws {
        logger.info("Typing text: \(text.prefix(30))... (pressReturn: \(pressReturn))")
        let escaped = escapeForAppleScript(text)
        let returnClause = pressReturn ? """

                delay 0.1
                keystroke return
        """ : ""
        let script = """
        tell application "System Events"
            tell (first process whose unix id is \(requirePID()))
                set frontmost to true
                keystroke "\(escaped)"\(returnClause)
            end tell
        end tell
        """
        try await runAppleScript(script)
    }

    // MARK: - Unpair

    /// Trigger unpair on the first paired viewer via the macOS app's test HTTP endpoint.
    /// Bypasses the SwiftUI Menu (whose NSMenu popup isn't in the accessibility tree).
    public func unpair() async throws {
        logger.info("Triggering unpair via HTTP endpoint")
        let success = try await MacAppHTTPClient.unpair(port: httpPort)
        if !success {
            throw MacOSDriverError.elementNotFound("unpair endpoint returned failure")
        }
    }

    // MARK: - Wait for Element

    /// Wait for an element with the given title to appear in the macOS app
    public func waitForElement(titled: String, timeout: TimeInterval = 10) async throws {
        _ = try await waitForHTTPElement(titled: titled, timeout: timeout)
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

    // MARK: - Private: HTTP Element Interaction

    /// Wait for an element to appear in the HTTP accessibility tree
    private func waitForHTTPElement(
        titled: String,
        timeout: TimeInterval
    ) async throws -> MacAppHTTPClient.MacUIElement {
        try await Polling.waitFor(
            description: "macOS UI element '\(titled)'",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            try? await MacAppHTTPClient.findElement(titled: titled, port: self.httpPort)
        }
    }

    /// Click at absolute screen coordinates using CGEvent
    private func clickAtScreenPoint(_ point: CGPoint) async throws {
        logger.info("Clicking at screen coordinates: (\(point.x), \(point.y))")

        // Bring the app's windows to front via HTTP endpoint
        try await MacAppHTTPClient.activate(port: httpPort)
        try await Task.sleep(for: .milliseconds(300))

        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )

        mouseDown?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(50))
        mouseUp?.post(tap: .cghidEventTap)
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

    private func requirePID() -> pid_t {
        guard let pid = appPID else {
            fatalError("MacOSDriver: no app PID — call launchApp first")
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
        }
    }
}
