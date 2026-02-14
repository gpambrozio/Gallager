import AppKit
import CoreGraphics
import Foundation
import Logging

/// Drives the macOS Gallager app via HTTP accessibility server, CGEvent, and AppleScript
public actor MacOSDriver {
    private let processRunner = ProcessRunner()
    private let logger = Logger(label: "e2e.macos-driver")

    private var appPath: String?
    private let appName = "Gallager"

    public init() { }

    // MARK: - App Lifecycle

    /// Launch the macOS app
    public func launchApp(path: String, arguments: [String] = []) async throws {
        logger.info("Launching macOS app: \(path)")
        appPath = path

        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = ["LOG_LEVEL": "debug"]

        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        // Wait for the app to launch
        try await Task.sleep(for: .seconds(2))
    }

    /// Terminate the macOS app
    public func terminateApp() async throws {
        logger.info("Terminating macOS app")
        let script = "tell application \"\(appName)\" to quit"
        try await runAppleScript(script)
        try await Task.sleep(for: .seconds(1))
    }

    // MARK: - Settings Navigation

    /// Open the Settings window via the status item menu
    public func openSettings() async throws {
        logger.info("Opening Settings via status item menu")
        let script = """
        tell application "System Events"
            tell process "\(appName)"
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
            await MacAppHTTPClient.windowExists(titled: titled)
        }
    }

    /// Select a tab in the Settings window by clicking it via the app's HTTP server.
    /// The click happens inside the app process, bypassing window z-ordering issues.
    public func selectSettingsTab(_ tabName: String) async throws {
        logger.info("Selecting settings tab: \(tabName)")
        // Wait for the element to appear, then click via HTTP
        _ = try await waitForHTTPElement(titled: tabName, timeout: 5)
        let clicked = try await MacAppHTTPClient.click(titled: tabName)
        if !clicked {
            throw MacOSDriverError.elementNotFound(tabName)
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Click a button by title or help text via the app's HTTP server.
    public func clickButton(titled: String) async throws {
        logger.info("Clicking button: \(titled)")
        _ = try await waitForHTTPElement(titled: titled, timeout: 5)
        let clicked = try await MacAppHTTPClient.click(titled: titled)
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
        let clicked = try await MacAppHTTPClient.click(titled: menuButtonTitle)
        if !clicked {
            throw MacOSDriverError.elementNotFound(menuButtonTitle)
        }

        // Step 2: Poll for the menu item (popup needs time to appear and populate)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            let itemClicked = try await MacAppHTTPClient.click(titled: itemTitle)
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
            tell process "\(appName)"
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
        let resized = try await MacAppHTTPClient.resizeWindow(width: width, height: height)
        if !resized {
            throw MacOSDriverError.appleScriptFailed(
                "Failed to resize window to \(width)x\(height) — no visible window found"
            )
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
            tell process "\(appName)"
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
        let success = try await MacAppHTTPClient.unpair()
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
            try? await MacAppHTTPClient.findElement(titled: titled)
        }
    }

    /// Click at absolute screen coordinates using CGEvent
    private func clickAtScreenPoint(_ point: CGPoint) async throws {
        logger.info("Clicking at screen coordinates: (\(point.x), \(point.y))")

        // Bring the app's windows to front via HTTP endpoint
        try await MacAppHTTPClient.activate()
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

    // MARK: - Private: CGWindowList

    /// Finds the CGWindowID for the first on-screen window owned by our app.
    private func getWindowID() -> CGWindowID? {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard
                let ownerName = window[kCGWindowOwnerName as String] as? String,
                ownerName == appName,
                let windowNumber = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return windowNumber
        }
        return nil
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
