import AppKit
import Foundation
import Logging

// MARK: - Terminal App

/// Terminal applications that can be used to attach to tmux sessions
public enum TerminalApp: String, CaseIterable, Sendable {
    case terminalApp = "Terminal"
    case iterm2 = "iTerm2"
    case warp = "Warp"
    case kitty = "Kitty"
    case alacritty = "Alacritty"
    case custom = "Custom..."

    /// The bundle identifier for the terminal app
    public var bundleIdentifier: String? {
        switch self {
        case .terminalApp: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .warp: "dev.warp.Warp-Stable"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        case .custom: nil
        }
    }

    /// Check if this terminal app is installed
    @MainActor
    public var isInstalled: Bool {
        guard let bundleId = bundleIdentifier else { return true } // custom is always "available"
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
}

// MARK: - Terminal Launcher

/// Launches tmux sessions in external terminal applications.
///
/// Supports multiple terminal emulators including Terminal.app, iTerm2, Warp, Kitty, and Alacritty.
@MainActor
final public class TerminalLauncher {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.terminallauncher")
    private let settings: AppSettings

    // MARK: - Initialization

    public init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Attach to a tmux session in the configured terminal application
    /// - Parameter sessionName: The name of the tmux session to attach to
    /// - Throws: `TerminalLauncherError` if the terminal cannot be launched
    public func attachToSession(_ sessionName: String) async throws {
        let terminalApp = settings.terminalApp
        let tmuxPath = settings.tmuxPath
        let tmuxSocket = settings.tmuxSocket

        logger.info("Attaching to session", metadata: [
            "session": "\(sessionName)",
            "terminal": "\(terminalApp.rawValue)",
        ])

        switch terminalApp {
        case .terminalApp:
            try await launchInTerminalApp(sessionName: sessionName, tmuxPath: tmuxPath, tmuxSocket: tmuxSocket)
        case .iterm2:
            try await launchInITerm2(sessionName: sessionName, tmuxPath: tmuxPath, tmuxSocket: tmuxSocket)
        case .warp:
            try await launchInWarp(sessionName: sessionName, tmuxPath: tmuxPath, tmuxSocket: tmuxSocket)
        case .kitty:
            try await launchInKitty(sessionName: sessionName, tmuxPath: tmuxPath, tmuxSocket: tmuxSocket)
        case .alacritty:
            try await launchInAlacritty(sessionName: sessionName, tmuxPath: tmuxPath, tmuxSocket: tmuxSocket)
        case .custom:
            try await launchInCustomTerminal(sessionName: sessionName, tmuxPath: tmuxPath, tmuxSocket: tmuxSocket)
        }
    }

    // MARK: - Private Terminal Launchers

    private func launchInTerminalApp(sessionName: String, tmuxPath: String, tmuxSocket: String) async throws {
        let attachCommand = buildAttachCommand(tmuxPath: tmuxPath, tmuxSocket: tmuxSocket, sessionName: sessionName)
        let script = """
        tell application "Terminal"
            activate
            do script "\(attachCommand)"
        end tell
        """

        try await runAppleScript(script)
    }

    private func launchInITerm2(sessionName: String, tmuxPath: String, tmuxSocket: String) async throws {
        let attachCommand = buildAttachCommand(tmuxPath: tmuxPath, tmuxSocket: tmuxSocket, sessionName: sessionName)
        let script = """
        tell application "iTerm"
            activate
            create window with default profile command "\(attachCommand)"
        end tell
        """

        try await runAppleScript(script)
    }

    private func launchInWarp(sessionName: String, tmuxPath: String, tmuxSocket: String) async throws {
        // Warp doesn't have great AppleScript support, so we use its CLI
        // Warp will open a new window when launched with a command
        let attachCommand = buildAttachCommand(tmuxPath: tmuxPath, tmuxSocket: tmuxSocket, sessionName: sessionName)

        // First, activate Warp
        let script = """
        tell application "Warp" to activate
        """
        try await runAppleScript(script)

        // Then open a new tab and run the command using keyboard simulation
        // Warp doesn't have great scripting, so we use a workaround:
        // Open Warp and let user run the command manually, or use osascript keystroke
        try await Task.sleep(for: .milliseconds(500))

        let keystrokeScript = """
        tell application "System Events"
            tell process "Warp"
                keystroke "t" using command down
                delay 0.3
                keystroke "\(attachCommand)"
                keystroke return
            end tell
        end tell
        """
        try await runAppleScript(keystrokeScript)
    }

    private func launchInKitty(sessionName: String, tmuxPath: String, tmuxSocket: String) async throws {
        // Kitty has excellent CLI support
        let attachCommand = buildAttachCommand(tmuxPath: tmuxPath, tmuxSocket: tmuxSocket, sessionName: sessionName)

        let kittyPath = "/Applications/kitty.app/Contents/MacOS/kitty"
        guard FileManager.default.fileExists(atPath: kittyPath) else {
            throw TerminalLauncherError.terminalNotFound("Kitty not found at \(kittyPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: kittyPath)
        process.arguments = ["--single-instance", "--", "sh", "-c", attachCommand]

        try process.run()
    }

    private func launchInAlacritty(sessionName: String, tmuxPath: String, tmuxSocket: String) async throws {
        // Alacritty uses command-line arguments
        let attachCommand = buildAttachCommand(tmuxPath: tmuxPath, tmuxSocket: tmuxSocket, sessionName: sessionName)

        guard let alacrittyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.alacritty") else {
            throw TerminalLauncherError.terminalNotFound("Alacritty not found")
        }

        let alacrittyPath = alacrittyURL.appendingPathComponent("Contents/MacOS/alacritty").path
        guard FileManager.default.fileExists(atPath: alacrittyPath) else {
            throw TerminalLauncherError.terminalNotFound("Alacritty executable not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: alacrittyPath)
        process.arguments = ["-e", "sh", "-c", attachCommand]

        try process.run()
    }

    private func launchInCustomTerminal(sessionName: String, tmuxPath: String, tmuxSocket: String) async throws {
        let customPath = settings.customTerminalPath
        guard !customPath.isEmpty else {
            throw TerminalLauncherError.customPathNotSet
        }

        let url = URL(fileURLWithPath: customPath)
        guard FileManager.default.fileExists(atPath: customPath) else {
            throw TerminalLauncherError.terminalNotFound("Custom terminal not found at \(customPath)")
        }

        // For custom terminals, we just open the app - user may need to run attach manually
        // since we don't know what scripting support it has
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            logger.info("Opened custom terminal, user should run: tmux attach -t \(sessionName)")
        } catch {
            throw TerminalLauncherError.launchFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func buildAttachCommand(tmuxPath: String, tmuxSocket: String, sessionName: String) -> String {
        var cmd = tmuxPath
        if !tmuxSocket.isEmpty {
            cmd += " -S \(tmuxSocket)"
        }
        cmd += " attach -t \(sessionName)"
        return cmd
    }

    private func runAppleScript(_ script: String) async throws {
        let appleScript = NSAppleScript(source: script)

        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw TerminalLauncherError.appleScriptFailed(message)
        }
    }
}

// MARK: - Errors

public enum TerminalLauncherError: LocalizedError {
    case terminalNotFound(String)
    case customPathNotSet
    case appleScriptFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .terminalNotFound(message):
            "Terminal not found: \(message)"
        case .customPathNotSet:
            "Custom terminal path is not configured. Please set it in Settings."
        case let .appleScriptFailed(message):
            "AppleScript error: \(message)"
        case let .launchFailed(message):
            "Failed to launch terminal: \(message)"
        }
    }
}
