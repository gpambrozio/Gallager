import AppKit
import Foundation
import Logging

/// Drives the macOS ClaudeSpyServer app via AppleScript and NSWorkspace
public actor MacOSDriver {
    private let processRunner = ProcessRunner()
    private let logger = Logger(label: "e2e.macos-driver")

    private var appPath: String?
    private let appName = "ClaudeSpyServer"

    public init() { }

    // MARK: - App Lifecycle

    /// Launch the macOS app
    public func launchApp(path: String, arguments: [String] = []) async throws {
        logger.info("Launching macOS app: \(path)")
        appPath = path

        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments

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

    /// Open the Settings window (Cmd+,)
    public func openSettings() async throws {
        logger.info("Opening Settings")
        let script = """
        tell application "\(appName)" to activate
        delay 0.5
        tell application "System Events"
            keystroke "," using command down
        end tell
        delay 0.5
        """
        try await runAppleScript(script)
    }

    /// Wait for a window to appear
    public func waitForWindow(titled: String, timeout: TimeInterval = 5) async throws {
        let name = appName
        try await Polling.waitUntil(
            description: "window titled \"\(titled)\"",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            await self.checkWindowExists(appName: name, title: titled)
        }
    }

    /// Check if a window with the given title exists (helper for polling)
    private func checkWindowExists(appName: String, title: String) async -> Bool {
        // Note: `whose title contains` fails with error -1728 in System Events,
        // so we iterate manually instead.
        let script = """
        tell application "System Events"
            tell process "\(appName)"
                set windowTitles to title of every window
                repeat with t in windowTitles
                    if t contains "\(title)" then return true
                end repeat
                return false
            end tell
        end tell
        """
        return (try? await runAppleScriptReturning(script)) == "true"
    }

    /// Select a tab in the Settings window
    public func selectSettingsTab(_ tabName: String) async throws {
        logger.info("Selecting settings tab: \(tabName)")
        let script = """
        tell application "System Events"
            tell process "\(appName)"
                tell toolbar 1 of window 1
                    click button "\(tabName)"
                end tell
            end tell
        end tell
        delay 0.3
        """
        try await runAppleScript(script)
    }

    /// Click a button by title or help text (searches recursively)
    ///
    /// Matches against both the button's `title` and `help` (AXHelp) attributes,
    /// since SwiftUI buttons often lack a title but expose `.help()` as AXHelp.
    public func clickButton(titled: String) async throws {
        logger.info("Clicking button: \(titled)")
        let script = """
        on findAndClickButton(theElement, buttonLabel)
            tell application "System Events"
                repeat with btn in (buttons of theElement)
                    try
                        if (title of btn) is buttonLabel then
                            click btn
                            return true
                        end if
                    end try
                    try
                        if (help of btn) is buttonLabel then
                            click btn
                            return true
                        end if
                    end try
                end repeat
                repeat with child in (UI elements of theElement)
                    set found to my findAndClickButton(child, buttonLabel)
                    if found then return true
                end repeat
            end tell
            return false
        end findAndClickButton

        tell application "System Events"
            tell process "\(appName)"
                set frontmost to true
                delay 0.2
                my findAndClickButton(window 1, "\(titled)")
            end tell
        end tell
        """
        try await runAppleScript(script)
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

    // MARK: - Private Helpers

    /// Finds the CGWindowID for the first on-screen window owned by our app.
    private func getWindowID() -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
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

    public var errorDescription: String? {
        switch self {
        case .appNotRunning:
            "macOS app is not running"
        case let .appleScriptFailed(message):
            "AppleScript failed: \(message)"
        case let .windowNotFound(title):
            "Window not found: \(title)"
        }
    }
}
