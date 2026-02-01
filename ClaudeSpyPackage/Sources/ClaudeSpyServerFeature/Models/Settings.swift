import AppKit
import Foundation
import SwiftUI

/// Settings tab for programmatic navigation
public enum SettingsTab: String, Sendable {
    case general
    case remoteAccess
    case plugin
}

/// Application settings with persistent storage
@Observable
@MainActor
final public class AppSettings {
    // MARK: - UI State (transient, not persisted)

    /// Currently selected settings tab (for programmatic navigation)
    public var selectedSettingsTab: SettingsTab = .general

    // MARK: - Terminal Settings

    /// Font name for terminal display
    public var fontName: String {
        didSet { UserDefaults.standard.set(fontName, forKey: Keys.fontName) }
    }

    /// Font size for terminal display
    public var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    /// Number of scrollback lines to keep
    public var scrollbackLines: Int {
        didSet { UserDefaults.standard.set(scrollbackLines, forKey: Keys.scrollbackLines) }
    }

    /// Terminal color theme
    public var theme: TerminalTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    // MARK: - Behavior Settings

    /// Whether to restore windows on launch
    public var restoreWindowsOnLaunch: Bool {
        didSet { UserDefaults.standard.set(restoreWindowsOnLaunch, forKey: Keys.restoreWindowsOnLaunch) }
    }

    /// Whether to show the status bar in mirror windows
    public var showStatusBar: Bool {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: Keys.showStatusBar) }
    }

    /// Whether to auto-reconnect on connection loss
    public var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: Keys.autoReconnect) }
    }

    /// Whether to automatically open mirror window when Claude session starts
    public var autoOpenMirrorOnSession: Bool {
        didSet { UserDefaults.standard.set(autoOpenMirrorOnSession, forKey: Keys.autoOpenMirrorOnSession) }
    }

    /// Whether to prevent Mac from sleeping while Claude sessions are active
    public var preventSleepDuringSessions: Bool {
        didSet { UserDefaults.standard.set(preventSleepDuringSessions, forKey: Keys.preventSleepDuringSessions) }
    }

    /// Delay before attempting reconnection (in seconds)
    public var reconnectDelay: Int {
        didSet { UserDefaults.standard.set(reconnectDelay, forKey: Keys.reconnectDelay) }
    }

    // MARK: - tmux Settings

    /// Path to tmux binary
    public var tmuxPath: String {
        didSet { UserDefaults.standard.set(tmuxPath, forKey: Keys.tmuxPath) }
    }

    /// Whether to automatically run a command when creating sessions in project folders
    public var autoRunClaudeInProjects: Bool {
        didSet { UserDefaults.standard.set(autoRunClaudeInProjects, forKey: Keys.autoRunClaudeInProjects) }
    }

    /// Path to claude command (for auto-run in project folders)
    public var claudeCommandPath: String {
        didSet { UserDefaults.standard.set(claudeCommandPath, forKey: Keys.claudeCommandPath) }
    }

    /// tmux socket path (empty for default)
    public var tmuxSocket: String {
        didSet { UserDefaults.standard.set(tmuxSocket, forKey: Keys.tmuxSocket) }
    }

    /// Terminal application to use for attaching to sessions
    public var terminalApp: TerminalApp {
        didSet { UserDefaults.standard.set(terminalApp.rawValue, forKey: Keys.terminalApp) }
    }

    /// Path to custom terminal application (when terminalApp is .custom)
    public var customTerminalPath: String {
        didSet { UserDefaults.standard.set(customTerminalPath, forKey: Keys.customTerminalPath) }
    }

    // MARK: - Remote Access Settings

    /// URL of the external relay server
    public var externalServerURL: String {
        didSet { UserDefaults.standard.set(externalServerURL, forKey: Keys.externalServerURL) }
    }

    /// Pair ID from successful device pairing (nil if not paired)
    public var pairId: String? {
        didSet { UserDefaults.standard.set(pairId, forKey: Keys.pairId) }
    }

    /// Name of paired iOS device (nil if not paired)
    public var pairedDeviceName: String? {
        didSet { UserDefaults.standard.set(pairedDeviceName, forKey: Keys.pairedDeviceName) }
    }

    /// Base64-encoded public key of paired iOS device for E2EE (nil if not paired)
    public var partnerPublicKey: String? {
        didSet { UserDefaults.standard.set(partnerPublicKey, forKey: Keys.partnerPublicKey) }
    }

    /// Public key ID of paired iOS device for E2EE (nil if not paired)
    public var partnerPublicKeyId: String? {
        didSet { UserDefaults.standard.set(partnerPublicKeyId, forKey: Keys.partnerPublicKeyId) }
    }

    /// Whether to automatically connect to relay server on launch
    public var autoConnectToServer: Bool {
        didSet { UserDefaults.standard.set(autoConnectToServer, forKey: Keys.autoConnectToServer) }
    }

    /// Unique device identifier for this Mac (generated on first launch)
    public var deviceId: String {
        didSet { UserDefaults.standard.set(deviceId, forKey: Keys.deviceId) }
    }

    // MARK: - Plugin Settings

    /// Whether the user has completed the plugin setup (or dismissed it)
    public var hasCompletedPluginSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedPluginSetup, forKey: Keys.hasCompletedPluginSetup) }
    }

    // MARK: - Initialization

    public init() {
        let defaults = UserDefaults.standard

        self.fontName = defaults.string(forKey: Keys.fontName) ?? Defaults.fontName
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Defaults.fontSize
        self.scrollbackLines = defaults.object(forKey: Keys.scrollbackLines) as? Int ?? Defaults.scrollbackLines
        self.theme = TerminalTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? Defaults.theme
        self.restoreWindowsOnLaunch = defaults.object(forKey: Keys.restoreWindowsOnLaunch) as? Bool ?? Defaults.restoreWindowsOnLaunch
        self.showStatusBar = defaults.object(forKey: Keys.showStatusBar) as? Bool ?? Defaults.showStatusBar
        self.autoReconnect = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? Defaults.autoReconnect
        self.autoOpenMirrorOnSession = defaults.object(forKey: Keys.autoOpenMirrorOnSession) as? Bool ?? Defaults.autoOpenMirrorOnSession
        self.preventSleepDuringSessions = defaults.object(forKey: Keys.preventSleepDuringSessions) as? Bool ?? Defaults.preventSleepDuringSessions
        self.reconnectDelay = defaults.object(forKey: Keys.reconnectDelay) as? Int ?? Defaults.reconnectDelay
        self.tmuxPath = defaults.string(forKey: Keys.tmuxPath) ?? Defaults.tmuxPath
        self.tmuxSocket = defaults.string(forKey: Keys.tmuxSocket) ?? Defaults.tmuxSocket

        // Claude command settings - auto-detect on first launch
        self.autoRunClaudeInProjects = defaults.object(forKey: Keys.autoRunClaudeInProjects) as? Bool ?? Defaults.autoRunClaudeInProjects
        if let savedPath = defaults.string(forKey: Keys.claudeCommandPath) {
            self.claudeCommandPath = savedPath
        } else {
            // First launch - try to detect claude path
            let detectedPath = Self.detectClaudePath() ?? Defaults.claudeCommandPath
            self.claudeCommandPath = detectedPath
            defaults.set(detectedPath, forKey: Keys.claudeCommandPath)
        }
        self.terminalApp = TerminalApp(rawValue: defaults.string(forKey: Keys.terminalApp) ?? "") ?? Defaults.terminalApp
        self.customTerminalPath = defaults.string(forKey: Keys.customTerminalPath) ?? Defaults.customTerminalPath

        // Remote Access
        self.externalServerURL = defaults.string(forKey: Keys.externalServerURL) ?? Defaults.externalServerURL
        self.pairId = defaults.string(forKey: Keys.pairId)
        self.pairedDeviceName = defaults.string(forKey: Keys.pairedDeviceName)
        self.partnerPublicKey = defaults.string(forKey: Keys.partnerPublicKey)
        self.partnerPublicKeyId = defaults.string(forKey: Keys.partnerPublicKeyId)
        self.autoConnectToServer = defaults.object(forKey: Keys.autoConnectToServer) as? Bool ?? Defaults.autoConnectToServer

        // Generate device ID if not already set
        if let existingDeviceId = defaults.string(forKey: Keys.deviceId) {
            self.deviceId = existingDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            self.deviceId = newDeviceId
            defaults.set(newDeviceId, forKey: Keys.deviceId)
        }

        // Plugin
        self.hasCompletedPluginSetup = defaults.object(forKey: Keys.hasCompletedPluginSetup) as? Bool ?? Defaults.hasCompletedPluginSetup
    }

    // MARK: - Keys

    private enum Keys {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let scrollbackLines = "scrollbackLines"
        static let theme = "theme"
        static let restoreWindowsOnLaunch = "restoreWindowsOnLaunch"
        static let showStatusBar = "showStatusBar"
        static let autoReconnect = "autoReconnect"
        static let autoOpenMirrorOnSession = "autoOpenMirrorOnSession"
        static let preventSleepDuringSessions = "preventSleepDuringSessions"
        static let reconnectDelay = "reconnectDelay"
        static let tmuxPath = "tmuxPath"
        static let tmuxSocket = "tmuxSocket"
        static let autoRunClaudeInProjects = "autoRunClaudeInProjects"
        static let claudeCommandPath = "claudeCommandPath"
        static let terminalApp = "terminalApp"
        static let customTerminalPath = "customTerminalPath"
        // Remote Access
        static let externalServerURL = "externalServerURL"
        static let pairId = "pairId"
        static let pairedDeviceName = "pairedDeviceName"
        static let partnerPublicKey = "partnerPublicKey"
        static let partnerPublicKeyId = "partnerPublicKeyId"
        static let autoConnectToServer = "autoConnectToServer"
        static let deviceId = "deviceId"
        // Plugin
        static let hasCompletedPluginSetup = "hasCompletedPluginSetup"
    }

    // MARK: - Defaults

    private enum Defaults {
        static let fontName = "SF Mono"
        // swiftlint:disable:next custom_no_number_decimals
        static let fontSize = 12.0
        static let scrollbackLines = 10_000
        static let theme = TerminalTheme.defaultDark
        static let restoreWindowsOnLaunch = true
        static let showStatusBar = true
        static let autoReconnect = false
        static let autoOpenMirrorOnSession = false
        static let preventSleepDuringSessions = true
        static let reconnectDelay = 5
        static let tmuxPath = "/opt/homebrew/bin/tmux"
        static let tmuxSocket = ""
        static let autoRunClaudeInProjects = true
        static let claudeCommandPath = "claude"
        static let terminalApp = TerminalApp.terminalApp
        static let customTerminalPath = ""
        // Remote Access
        static let externalServerURL = "wss://claudespy.gustavo.eng.br"
        static let autoConnectToServer = true
        // Plugin
        static let hasCompletedPluginSetup = false
    }

    // MARK: - Computed Properties

    /// Whether the device is paired with an iOS device
    public var isPaired: Bool {
        pairId != nil
    }

    /// Clear pairing data (for unpair operation)
    public func clearPairing() {
        pairId = nil
        pairedDeviceName = nil
        partnerPublicKey = nil
        partnerPublicKeyId = nil
    }

    /// Save pairing data including partner's public key for E2EE
    public func savePairing(
        pairId: String,
        partnerDeviceName: String?,
        partnerPublicKey: String?,
        partnerPublicKeyId: String?
    ) {
        self.pairId = pairId
        pairedDeviceName = partnerDeviceName
        self.partnerPublicKey = partnerPublicKey
        self.partnerPublicKeyId = partnerPublicKeyId
    }

    // MARK: - Path Detection

    /// Attempts to detect the claude command path using common locations and `which`
    private static func detectClaudePath() -> String? {
        // Common installation paths for Claude Code
        let commonPaths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSString("~/.local/bin/claude").expandingTildeInPath,
            NSString("~/.claude/local/claude").expandingTildeInPath,
        ]

        let fileManager = FileManager.default

        // Check common paths first
        for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        // Try using `which` command as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if
                    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !path.isEmpty {
                    return path
                }
            }
        } catch {
            // which failed, return nil
        }

        return nil
    }
}

// MARK: - Terminal Theme

public enum TerminalTheme: String, CaseIterable, Sendable {
    case defaultDark = "Default Dark"
    case defaultLight = "Default Light"
    case solarizedDark = "Solarized Dark"
    case solarizedLight = "Solarized Light"
}
