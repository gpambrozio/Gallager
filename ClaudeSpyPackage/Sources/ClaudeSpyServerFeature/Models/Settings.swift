import AppKit
import ClaudeSpyCommon
import Dependencies
import Foundation
import SwiftUI

// MARK: - PreferencesService + AppSettings.Keys

extension PreferencesService {
    func string(_ key: AppSettings.Keys) -> String? { string(key.rawValue) }
    func setString(_ value: String?, _ key: AppSettings.Keys) { setString(value, key.rawValue) }
    func optionalBool(_ key: AppSettings.Keys) -> Bool? { optionalBool(key.rawValue) }
    func setBool(_ value: Bool, _ key: AppSettings.Keys) { setBool(value, key.rawValue) }
    func optionalInt(_ key: AppSettings.Keys) -> Int? { optionalInt(key.rawValue) }
    func setInt(_ value: Int, _ key: AppSettings.Keys) { setInt(value, key.rawValue) }
    func optionalDouble(_ key: AppSettings.Keys) -> Double? { optionalDouble(key.rawValue) }
    func setDouble(_ value: Double, _ key: AppSettings.Keys) { setDouble(value, key.rawValue) }
    func data(_ key: AppSettings.Keys) -> Data? { data(key.rawValue) }
    func setData(_ value: Data?, _ key: AppSettings.Keys) { setData(value, key.rawValue) }
}

/// Settings tab for programmatic navigation
public enum SettingsTab: String, Sendable {
    case general
    case remoteAccess
    case remoteHosts
    case sidebarLayout
    case plugin
    case about
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
    // MARK: - Dependencies

    /// Preferences service for persistent storage
    @ObservationIgnored
    @Dependency(PreferencesService.self) private var preferences

    @ObservationIgnored
    @Dependency(ClaudePathDetector.self) private var claudePathDetector

    @ObservationIgnored
    @Dependency(LoginItemService.self) private var loginItemService

    // MARK: - UI State (transient, not persisted)

    /// Currently selected settings tab (for programmatic navigation)
    public var selectedSettingsTab: SettingsTab = .general

    // MARK: - Terminal Settings

    /// Font name for terminal display
    public var fontName: String = Defaults.fontName {
        didSet { preferences.setString(fontName, Keys.fontName) }
    }

    /// Font size for terminal display
    public var fontSize: Double = Defaults.fontSize {
        didSet { preferences.setDouble(fontSize, Keys.fontSize) }
    }

    /// Number of scrollback lines to keep
    public var scrollbackLines: Int = Defaults.scrollbackLines {
        didSet { preferences.setInt(scrollbackLines, Keys.scrollbackLines) }
    }

    /// Terminal color theme
    public var theme: TerminalTheme = Defaults.theme {
        didSet { preferences.setString(theme.rawValue, Keys.theme) }
    }

    // MARK: - Behavior Settings

    /// Whether to open the panes window when the app launches
    public var openPanesWindowOnLaunch: Bool = Defaults.openPanesWindowOnLaunch {
        didSet { preferences.setBool(openPanesWindowOnLaunch, Keys.openPanesWindowOnLaunch) }
    }

    /// Whether to show the status bar in mirror windows
    public var showStatusBar: Bool = Defaults.showStatusBar {
        didSet { preferences.setBool(showStatusBar, Keys.showStatusBar) }
    }

    /// Whether to auto-reconnect on connection loss
    public var autoReconnect: Bool = Defaults.autoReconnect {
        didSet { preferences.setBool(autoReconnect, Keys.autoReconnect) }
    }

    /// Whether to prevent host from sleeping while Claude sessions are active
    public var preventSleepDuringSessions: Bool = Defaults.preventSleepDuringSessions {
        didSet { preferences.setBool(preventSleepDuringSessions, Keys.preventSleepDuringSessions) }
    }

    /// Whether to automatically copy selected text to the clipboard when the mouse is released
    public var autoCopyOnSelect: Bool = Defaults.autoCopyOnSelect {
        didSet { preferences.setBool(autoCopyOnSelect, Keys.autoCopyOnSelect) }
    }

    /// When true, all terminal panes are always resized to fit the mirror view when the window size changes
    public var alwaysAutoResize: Bool = Defaults.alwaysAutoResize {
        didSet { preferences.setBool(alwaysAutoResize, Keys.alwaysAutoResize) }
    }

    /// Delay before attempting reconnection (in seconds)
    public var reconnectDelay: Int = Defaults.reconnectDelay {
        didSet { preferences.setInt(reconnectDelay, Keys.reconnectDelay) }
    }

    // MARK: - tmux Settings

    /// Path to tmux binary
    public var tmuxPath: String = Defaults.tmuxPath {
        didSet { preferences.setString(tmuxPath, Keys.tmuxPath) }
    }

    /// Whether to automatically run a command when creating sessions in project folders
    public var autoRunClaudeInProjects: Bool = Defaults.autoRunClaudeInProjects {
        didSet { preferences.setBool(autoRunClaudeInProjects, Keys.autoRunClaudeInProjects) }
    }

    /// Path to claude command (for auto-run in project folders)
    public var claudeCommandPath: String = Defaults.claudeCommandPath {
        didSet { preferences.setString(claudeCommandPath, Keys.claudeCommandPath) }
    }

    /// tmux socket path (empty for default)
    public var tmuxSocket: String = Defaults.tmuxSocket {
        didSet { preferences.setString(tmuxSocket, Keys.tmuxSocket) }
    }

    /// Terminal application to use for attaching to sessions
    public var terminalApp: TerminalApp = Defaults.terminalApp {
        didSet { preferences.setString(terminalApp.rawValue, Keys.terminalApp) }
    }

    /// Path to custom terminal application (when terminalApp is .custom)
    public var customTerminalPath: String = Defaults.customTerminalPath {
        didSet { preferences.setString(customTerminalPath, Keys.customTerminalPath) }
    }

    // MARK: - Remote Access Settings

    /// URL of the external relay server
    public var externalServerURL: String = Defaults.externalServerURL {
        didSet { preferences.setString(externalServerURL, Keys.externalServerURL) }
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
    public var autoConnectToServer: Bool = Defaults.autoConnectToServer {
        didSet { preferences.setBool(autoConnectToServer, Keys.autoConnectToServer) }
    }

    /// Unique device identifier for this host (generated on first launch)
    public var deviceId = "" {
        didSet { preferences.setString(deviceId, Keys.deviceId) }
    }

    // MARK: - Sidebar Layout Settings

    /// Ordered list of fields to display in sidebar session rows
    public var sidebarFields: [SidebarField] = SidebarField.defaultFields {
        didSet { saveSidebarFields() }
    }

    /// Ordered list of fields to display in sidebar terminal rows (no Claude session)
    public var sidebarTerminalFields: [SidebarField] = SidebarField.defaultTerminalFields {
        didSet { saveSidebarTerminalFields() }
    }

    /// How sessions are sorted in the sidebar
    public var sidebarSortMode: SidebarSortMode = .statusPriorityIdleFirst {
        didSet { preferences.setString(sidebarSortMode.rawValue, Keys.sidebarSortMode) }
    }

    // MARK: - Plugin Settings

    /// Whether the user has completed the plugin setup (or dismissed it)
    public var hasCompletedPluginSetup: Bool = Defaults.hasCompletedPluginSetup {
        didSet { preferences.setBool(hasCompletedPluginSetup, Keys.hasCompletedPluginSetup) }
    }

    // MARK: - Launch at Login Settings

    /// Whether the app should launch at login (synced with system login items)
    public var launchAtLogin: Bool = Defaults.launchAtLogin {
        didSet { preferences.setBool(launchAtLogin, Keys.launchAtLogin) }
    }

    /// Whether the user has been asked about launching at login
    public var hasAskedAboutLaunchAtLogin: Bool = Defaults.hasAskedAboutLaunchAtLogin {
        didSet { preferences.setBool(hasAskedAboutLaunchAtLogin, Keys.hasAskedAboutLaunchAtLogin) }
    }

    // MARK: - Initialization

    public init() {
        self.fontName = preferences.string(Keys.fontName) ?? Defaults.fontName
        self.fontSize = preferences.optionalDouble(Keys.fontSize) ?? Defaults.fontSize
        self.scrollbackLines = preferences.optionalInt(Keys.scrollbackLines) ?? Defaults.scrollbackLines
        self.theme = TerminalTheme(rawValue: preferences.string(Keys.theme) ?? "") ?? Defaults.theme
        self.openPanesWindowOnLaunch = preferences.optionalBool(Keys.openPanesWindowOnLaunch) ?? Defaults.openPanesWindowOnLaunch
        self.showStatusBar = preferences.optionalBool(Keys.showStatusBar) ?? Defaults.showStatusBar
        self.autoReconnect = preferences.optionalBool(Keys.autoReconnect) ?? Defaults.autoReconnect
        self.preventSleepDuringSessions = preferences.optionalBool(Keys.preventSleepDuringSessions) ?? Defaults.preventSleepDuringSessions
        self.autoCopyOnSelect = preferences.optionalBool(Keys.autoCopyOnSelect) ?? Defaults.autoCopyOnSelect
        self.alwaysAutoResize = preferences.optionalBool(Keys.alwaysAutoResize) ?? Defaults.alwaysAutoResize
        self.reconnectDelay = preferences.optionalInt(Keys.reconnectDelay) ?? Defaults.reconnectDelay
        self.tmuxPath = preferences.string(Keys.tmuxPath) ?? Defaults.tmuxPath
        self.tmuxSocket = preferences.string(Keys.tmuxSocket) ?? Defaults.tmuxSocket

        // Claude command settings - auto-detect on first launch
        self.autoRunClaudeInProjects = preferences.optionalBool(Keys.autoRunClaudeInProjects) ?? Defaults.autoRunClaudeInProjects
        if let savedPath = preferences.string(Keys.claudeCommandPath) {
            self.claudeCommandPath = savedPath
        } else {
            // First launch - try to detect claude path
            let detectedPath = claudePathDetector.detectPath() ?? Defaults.claudeCommandPath
            self.claudeCommandPath = detectedPath
            preferences.setString(detectedPath, Keys.claudeCommandPath)
        }
        self.terminalApp = TerminalApp(rawValue: preferences.string(Keys.terminalApp) ?? "") ?? Defaults.terminalApp
        self.customTerminalPath = preferences.string(Keys.customTerminalPath) ?? Defaults.customTerminalPath

        // Remote Access
        self.externalServerURL = preferences.string(Keys.externalServerURL) ?? Defaults.externalServerURL
        self.autoConnectToServer = preferences.optionalBool(Keys.autoConnectToServer) ?? Defaults.autoConnectToServer

        // Load paired devices and hosts
        self.pairedViewers = Self.loadCodable(from: preferences, key: Keys.pairedViewers)
        self.pairedHosts = Self.loadCodable(from: preferences, key: Keys.pairedHosts)

        // Generate device ID if not already set
        if let existingDeviceId = preferences.string(Keys.deviceId) {
            self.deviceId = existingDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            self.deviceId = newDeviceId
            preferences.setString(newDeviceId, Keys.deviceId)
        }

        // Sidebar Layout
        self.sidebarFields = Self.loadCodable(from: preferences, key: Keys.sidebarFields)
        if sidebarFields.isEmpty {
            self.sidebarFields = SidebarField.defaultFields
        }
        self.sidebarTerminalFields = Self.loadCodable(from: preferences, key: Keys.sidebarTerminalFields)
        if sidebarTerminalFields.isEmpty {
            self.sidebarTerminalFields = SidebarField.defaultTerminalFields
        }
        self.sidebarSortMode = SidebarSortMode(
            rawValue: preferences.string(Keys.sidebarSortMode) ?? ""
        ) ?? .statusPriorityIdleFirst

        // Plugin
        self.hasCompletedPluginSetup = preferences.optionalBool(Keys.hasCompletedPluginSetup) ?? Defaults.hasCompletedPluginSetup

        // Launch at Login
        self.launchAtLogin = preferences.optionalBool(Keys.launchAtLogin) ?? Defaults.launchAtLogin
        self.hasAskedAboutLaunchAtLogin = preferences.optionalBool(Keys.hasAskedAboutLaunchAtLogin) ?? Defaults.hasAskedAboutLaunchAtLogin
    }

    // MARK: - Keys

    public enum Keys: String {
        case fontName
        case fontSize
        case scrollbackLines
        case theme
        case openPanesWindowOnLaunch
        case showStatusBar
        case autoReconnect
        case preventSleepDuringSessions
        case autoCopyOnSelect
        case alwaysAutoResize
        case reconnectDelay
        case tmuxPath
        case tmuxSocket
        case autoRunClaudeInProjects
        case claudeCommandPath
        case terminalApp
        case customTerminalPath
        // Remote Access
        case externalServerURL
        case pairedViewers = "pairedDevices"
        case pairedHosts
        case autoConnectToServer
        case deviceId
        // Sidebar Layout
        case sidebarFields
        case sidebarTerminalFields
        case sidebarSortMode
        // Plugin
        case hasCompletedPluginSetup
        // Launch at Login
        case launchAtLogin
        case hasAskedAboutLaunchAtLogin
    }

    // MARK: - Defaults

    private enum Defaults {
        static let fontName = "SF Mono"
        // swiftlint:disable:next custom_no_number_decimals
        static let fontSize = 12.0
        static let scrollbackLines = 10_000
        static let theme = TerminalTheme.defaultDark
        static let openPanesWindowOnLaunch = true
        static let showStatusBar = true
        static let autoReconnect = true
        static let preventSleepDuringSessions = true
        static let autoCopyOnSelect = true
        static let alwaysAutoResize = true
        static let reconnectDelay = 2
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

    // MARK: - Codable Storage

    private static func loadCodable<T: Decodable>(from preferences: PreferencesService, key: Keys) -> [T] {
        guard let data = preferences.data(key) else {
            return []
        }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func savePairedViewers() {
        guard let data = try? JSONEncoder().encode(pairedViewers) else {
            return
        }
        preferences.setData(data, Keys.pairedViewers)
    }

    private func savePairedHosts() {
        guard let data = try? JSONEncoder().encode(pairedHosts) else {
            return
        }
        preferences.setData(data, Keys.pairedHosts)
    }

    private func saveSidebarFields() {
        guard let data = try? JSONEncoder().encode(sidebarFields) else {
            return
        }
        preferences.setData(data, Keys.sidebarFields)
    }

    private func saveSidebarTerminalFields() {
        guard let data = try? JSONEncoder().encode(sidebarTerminalFields) else {
            return
        }
        preferences.setData(data, Keys.sidebarTerminalFields)
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

    // MARK: - Login Item Management

    /// Whether the app is currently registered as a login item.
    ///
    /// Queries the system on each access — not reactive via Observation.
    /// Read this in `onAppear` rather than relying on it for reactive updates.
    public var isLoginItemEnabled: Bool {
        loginItemService.isEnabled()
    }

    /// Enables or disables the app as a login item.
    public func setLoginItemEnabled(_ enabled: Bool) throws {
        try loginItemService.setEnabled(enabled)
        launchAtLogin = enabled
    }
}

// MARK: - Terminal Theme

public enum TerminalTheme: String, CaseIterable, Sendable {
    case defaultDark = "Default Dark"
    case defaultLight = "Default Light"
    case solarizedDark = "Solarized Dark"
    case solarizedLight = "Solarized Light"
}
