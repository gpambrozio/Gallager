import AppKit
import ClaudeSpyCommon
import Foundation
import SwiftUI

/// Settings tab for programmatic navigation
public enum SettingsTab: String, Sendable {
    case general
    case remoteAccess
    case remoteHosts
    case plugin
}

// MARK: - Paired Viewer Model

/// Represents a paired viewer with all connection details.
///
/// Each viewer paired with the host app has its own unique `pairId`,
/// cryptographic keys for E2EE, and connection state.
public struct PairedViewer: Codable, Identifiable, Sendable, Hashable {
    // MARK: - Properties

    /// Unique pair identifier (also serves as Identifiable id)
    public let id: String

    /// Display name of the viewer
    public let deviceName: String

    /// Partner's public key for E2EE (Base64-encoded)
    public let partnerPublicKey: String

    /// Partner's public key ID for E2EE
    public let partnerPublicKeyId: String

    /// When this pairing was established
    public let pairedAt: Date

    /// Optional custom name set by user for this device
    public var customName: String?

    // MARK: - Computed Properties

    /// Display name for UI (custom name if set, otherwise device name)
    public var displayName: String {
        customName ?? deviceName
    }

    // MARK: - Initialization

    public init(
        id: String,
        deviceName: String,
        partnerPublicKey: String,
        partnerPublicKeyId: String,
        pairedAt: Date = Date(),
        customName: String? = nil
    ) {
        self.id = id
        self.deviceName = deviceName
        self.partnerPublicKey = partnerPublicKey
        self.partnerPublicKeyId = partnerPublicKeyId
        self.pairedAt = pairedAt
        self.customName = customName
    }
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

    /// Whether to prevent host from sleeping while Claude sessions are active
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

    /// All paired viewers
    public private(set) var pairedViewers: [PairedViewer] = [] {
        didSet { savePairedViewers() }
    }

    /// All paired hosts (for viewing remote hosts)
    public private(set) var pairedHosts: [PairedHost] = [] {
        didSet { savePairedHosts() }
    }

    /// Whether to automatically connect to relay server on launch
    public var autoConnectToServer: Bool {
        didSet { UserDefaults.standard.set(autoConnectToServer, forKey: Keys.autoConnectToServer) }
    }

    /// Unique device identifier for this host (generated on first launch)
    public var deviceId: String {
        didSet { UserDefaults.standard.set(deviceId, forKey: Keys.deviceId) }
    }

    // MARK: - Plugin Settings

    /// Whether the user has completed the plugin setup (or dismissed it)
    public var hasCompletedPluginSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedPluginSetup, forKey: Keys.hasCompletedPluginSetup) }
    }

    // MARK: - Launch at Login Settings

    /// Whether the app should launch at login (synced with system login items)
    public var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the user has been asked about launching at login
    public var hasAskedAboutLaunchAtLogin: Bool {
        didSet { UserDefaults.standard.set(hasAskedAboutLaunchAtLogin, forKey: Keys.hasAskedAboutLaunchAtLogin) }
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
            let detectedPath = ClaudePathDetector.detectPath() ?? Defaults.claudeCommandPath
            self.claudeCommandPath = detectedPath
            defaults.set(detectedPath, forKey: Keys.claudeCommandPath)
        }
        self.terminalApp = TerminalApp(rawValue: defaults.string(forKey: Keys.terminalApp) ?? "") ?? Defaults.terminalApp
        self.customTerminalPath = defaults.string(forKey: Keys.customTerminalPath) ?? Defaults.customTerminalPath

        // Remote Access
        self.externalServerURL = defaults.string(forKey: Keys.externalServerURL) ?? Defaults.externalServerURL
        self.autoConnectToServer = defaults.object(forKey: Keys.autoConnectToServer) as? Bool ?? Defaults.autoConnectToServer

        // Load paired devices and hosts
        self.pairedViewers = Self.loadPairedViewers(from: defaults)
        self.pairedHosts = Self.loadPairedHosts(from: defaults)

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

        // Launch at Login
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? Defaults.launchAtLogin
        self.hasAskedAboutLaunchAtLogin = defaults.object(forKey: Keys.hasAskedAboutLaunchAtLogin) as? Bool ?? Defaults.hasAskedAboutLaunchAtLogin
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
        static let pairedViewers = "pairedDevices"
        static let pairedHosts = "pairedHosts"
        static let autoConnectToServer = "autoConnectToServer"
        static let deviceId = "deviceId"
        // Plugin
        static let hasCompletedPluginSetup = "hasCompletedPluginSetup"
        // Launch at Login
        static let launchAtLogin = "launchAtLogin"
        static let hasAskedAboutLaunchAtLogin = "hasAskedAboutLaunchAtLogin"
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
        // Launch at Login
        static let launchAtLogin = false
        static let hasAskedAboutLaunchAtLogin = false
    }

    // MARK: - Computed Properties

    /// Whether at least one viewer is paired
    public var isPaired: Bool {
        !pairedViewers.isEmpty
    }

    /// Whether at least one remote host is paired
    public var hasRemoteHosts: Bool {
        !pairedHosts.isEmpty
    }

    // MARK: - Paired Viewers Storage

    private static func loadPairedViewers(from defaults: UserDefaults) -> [PairedViewer] {
        guard let data = defaults.data(forKey: Keys.pairedViewers) else {
            return []
        }
        return (try? JSONDecoder().decode([PairedViewer].self, from: data)) ?? []
    }

    private func savePairedViewers() {
        guard let data = try? JSONEncoder().encode(pairedViewers) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Keys.pairedViewers)
    }

    // MARK: - Paired Hosts Storage

    private static func loadPairedHosts(from defaults: UserDefaults) -> [PairedHost] {
        guard let data = defaults.data(forKey: Keys.pairedHosts) else {
            return []
        }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    private func savePairedHosts() {
        guard let data = try? JSONEncoder().encode(pairedHosts) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Keys.pairedHosts)
    }

    // MARK: - Pairing Management

    /// Add a new paired viewer
    public func addPairing(_ viewer: PairedViewer) {
        // Remove any existing pairing with same ID (update case)
        pairedViewers.removeAll { $0.id == viewer.id }
        pairedViewers.append(viewer)
    }

    /// Remove a paired viewer by ID
    public func removePairing(id: String) {
        pairedViewers.removeAll { $0.id == id }
    }

    /// Get a paired viewer by ID
    public func getPairing(id: String) -> PairedViewer? {
        pairedViewers.first { $0.id == id }
    }

    /// Update a paired viewer (e.g., custom name or partner key)
    public func updatePairing(_ viewer: PairedViewer) {
        if let index = pairedViewers.firstIndex(where: { $0.id == viewer.id }) {
            pairedViewers[index] = viewer
        }
    }

    /// Clear all pairings
    public func clearAllPairings() {
        pairedViewers = []
    }

    // MARK: - Host Pairing Management

    /// Add a new paired host (remote host to view)
    public func addHostPairing(_ host: PairedHost) {
        // Remove any existing pairing with same ID (update case)
        pairedHosts.removeAll { $0.id == host.id }
        pairedHosts.append(host)
    }

    /// Remove a paired host by ID
    public func removeHostPairing(id: String) {
        pairedHosts.removeAll { $0.id == id }
    }

    /// Get a paired host by ID
    public func getHostPairing(id: String) -> PairedHost? {
        pairedHosts.first { $0.id == id }
    }

    /// Update a paired host (e.g., custom name or partner key)
    public func updateHostPairing(_ host: PairedHost) {
        if let index = pairedHosts.firstIndex(where: { $0.id == host.id }) {
            pairedHosts[index] = host
        }
    }

    /// Clear all host pairings
    public func clearAllHostPairings() {
        pairedHosts = []
    }

    /// Check if any paired hosts have duplicate names (for disambiguation)
    public func hasDuplicateHostName(for host: PairedHost) -> Bool {
        let matchingNames = pairedHosts.filter {
            $0.hostName == host.hostName && $0.id != host.id
        }
        return !matchingNames.isEmpty
    }
}

// MARK: - Terminal Theme

public enum TerminalTheme: String, CaseIterable, Sendable {
    case defaultDark = "Default Dark"
    case defaultLight = "Default Light"
    case solarizedDark = "Solarized Dark"
    case solarizedLight = "Solarized Light"
}
