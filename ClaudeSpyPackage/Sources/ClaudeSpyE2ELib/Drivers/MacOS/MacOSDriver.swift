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
        try runAppleScript(script)
        try await Task.sleep(for: .seconds(1))
    }

    // MARK: - Settings Navigation

    /// Open the Settings window (Cmd+,)
    public func openSettings() throws {
        logger.info("Opening Settings")
        let script = """
        tell application "\(appName)" to activate
        delay 0.5
        tell application "System Events"
            keystroke "," using command down
        end tell
        delay 0.5
        """
        try runAppleScript(script)
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
    private func checkWindowExists(appName: String, title: String) -> Bool {
        let script = """
        tell application "System Events"
            tell process "\(appName)"
                return (count of windows whose title contains "\(title)") > 0
            end tell
        end tell
        """
        return (try? runAppleScriptReturning(script)) == "true"
    }

    /// Select a tab in the Settings window
    public func selectSettingsTab(_ tabName: String) throws {
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
        try runAppleScript(script)
    }

    /// Click a button by title (searches recursively)
    public func clickButton(titled: String) throws {
        logger.info("Clicking button: \(titled)")
        let script = """
        tell application "System Events"
            tell process "\(appName)"
                set frontmost to true
                delay 0.2
                click button "\(titled)" of group 1 of group 1 of window 1
            end tell
        end tell
        """

        // Try direct path first, fall back to recursive search
        do {
            try runAppleScript(script)
        } catch {
            logger.info("Direct button path failed, trying recursive search")
            let recursiveScript = """
            on findAndClickButton(theElement, buttonTitle)
                tell application "System Events"
                    try
                        click button buttonTitle of theElement
                        return true
                    end try
                    set theElements to UI elements of theElement
                    repeat with anElement in theElements
                        set result to my findAndClickButton(anElement, buttonTitle)
                        if result then return true
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
            try runAppleScript(recursiveScript)
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
        _ = try await processRunner.runOrThrow(
            "/usr/sbin/screencapture",
            arguments: ["-l", getWindowID(), output]
        )
    }

    // MARK: - Private Helpers

    private func getWindowID() -> String {
        // Use a simple approach - capture the frontmost window
        "0" // Will use screencapture without window ID (captures front window)
    }

    @discardableResult
    private func runAppleScript(_ source: String) throws -> String {
        try runAppleScriptReturning(source)
    }

    private func runAppleScriptReturning(_ source: String) throws -> String {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw MacOSDriverError.appleScriptFailed(message)
        }
        return result?.stringValue ?? ""
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
