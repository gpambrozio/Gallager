import AppKit
import ClaudeSpyCommon
import Dependencies
import Foundation
import SwiftUI

// MARK: - PreferencesService + AppSettings.Keys

extension PreferencesService {
    func string(_ key: AppSettings.Keys) -> String? {
        string(key.rawValue)
    }

    func setString(_ value: String?, _ key: AppSettings.Keys) {
        setString(value, key.rawValue)
    }

    func optionalBool(_ key: AppSettings.Keys) -> Bool? {
        optionalBool(key.rawValue)
    }

    func setBool(_ value: Bool, _ key: AppSettings.Keys) {
        setBool(value, key.rawValue)
    }

    func optionalInt(_ key: AppSettings.Keys) -> Int? {
        optionalInt(key.rawValue)
    }

    func setInt(_ value: Int, _ key: AppSettings.Keys) {
        setInt(value, key.rawValue)
    }

    func optionalDouble(_ key: AppSettings.Keys) -> Double? {
        optionalDouble(key.rawValue)
    }

    func setDouble(_ value: Double, _ key: AppSettings.Keys) {
        setDouble(value, key.rawValue)
    }

    func data(_ key: AppSettings.Keys) -> Data? {
        data(key.rawValue)
    }

    func setData(_ value: Data?, _ key: AppSettings.Keys) {
        setData(value, key.rawValue)
    }
}

/// Settings tab for programmatic navigation
public enum SettingsTab: String, Sendable {
    case general
    case appearance
    case browser
    case remoteAccess
    case remoteHosts
    case sidebarLayout
    case editors
    case plugin
    case about
}

/// Where a clicked http/https/ftp link in the terminal should open.
///
/// Drives the dialog presented to the user on a terminal link click and the
/// "remember my choice" outcome — picking a non-`.ask` value here suppresses
/// the prompt for subsequent clicks.
public enum BrowserLinkBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Show a confirmation dialog with an "Always do this" checkbox.
    case ask
    /// Open in a new browser tab next to the file/terminal tabs.
    case alwaysInApp
    /// Forward to the system's default browser via `NSWorkspace`.
    case alwaysInDefaultBrowser

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .ask: "Ask"
        case .alwaysInApp: "Always in app"
        case .alwaysInDefaultBrowser: "Always in default browser"
        }
    }
}

/// A per-domain rule that overrides ``AppSettings/browserLinkBehavior`` for
/// any http/https/ftp link whose host (case-insensitive) matches ``domain``.
///
/// Created by the user via the "Don't ask again for this domain" checkbox on
/// the link confirmation dialog, or directly from the Browser settings tab.
public struct BrowserDomainRule: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    /// Lowercased host (e.g. `example.com`) — never `.ask`-only domains.
    public var domain: String
    public var behavior: BrowserLinkBehavior

    public init(id: UUID = UUID(), domain: String, behavior: BrowserLinkBehavior) {
        self.id = id
        self.domain = domain.lowercased()
        self.behavior = behavior
    }
}

/// macOS-specific bridge from `AppearanceMode` to `NSAppearance`. The shared
/// enum lives in `ClaudeSpyCommon` so iOS can reuse it for
/// `.preferredColorScheme(_:)`.
public extension AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
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

    /// Display name of the viewer.
    /// Mutable so the viewer can rename their device on the iOS app and have
    /// the host pick up the new name without re-pairing.
    public var deviceName: String

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

    // MARK: - Appearance Settings

    /// Window appearance (System / Light / Dark). Applied to `NSApp.appearance`
    /// whenever it changes.
    ///
    /// Note: the didSet uses optional chaining because the App-protocol init
    /// runs before SwiftUI sets up `NSApplication`. The initial application is
    /// done explicitly via `applyAppearance()` from a SwiftUI lifecycle hook
    /// once `NSApp` exists.
    public var appearanceMode: AppearanceMode = Defaults.appearanceMode {
        didSet {
            preferences.setString(appearanceMode.rawValue, Keys.appearanceMode)
            applyAppearance()
        }
    }

    /// Apply the persisted appearance to `NSApp`. Safe to call multiple times.
    /// Must be invoked from a SwiftUI lifecycle hook (`.task`/`.onAppear`)
    /// after launch, since `NSApp` is not yet wired during App init —
    /// optional chaining keeps it a no-op until then.
    public func applyAppearance() {
        NSApp?.appearance = appearanceMode.nsAppearance
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

    /// Whether clicking a file:// link in the terminal opens the file in a new tab
    /// instead of forwarding the URL to the system (which would open it in the browser).
    public var openClickedFileInNewTab: Bool = Defaults.openClickedFileInNewTab {
        didSet { preferences.setBool(openClickedFileInNewTab, Keys.openClickedFileInNewTab) }
    }

    /// Always open new file tabs on the split-view right pane (issue #498).
    /// Off by default; when enabled, opening a file via terminal click or any
    /// other path routes the new tab to the right side instead of the left.
    public var alwaysOpenFilesInSplit: Bool = Defaults.alwaysOpenFilesInSplit {
        didSet { preferences.setBool(alwaysOpenFilesInSplit, Keys.alwaysOpenFilesInSplit) }
    }

    /// Where a clicked http/https/ftp link in the terminal should open.
    /// `.ask` shows a confirmation dialog with a remember-my-choice toggle that
    /// flips this setting on the user's behalf.
    public var browserLinkBehavior: BrowserLinkBehavior = Defaults.browserLinkBehavior {
        didSet { preferences.setString(browserLinkBehavior.rawValue, Keys.browserLinkBehavior) }
    }

    /// Per-domain overrides for ``browserLinkBehavior``.
    ///
    /// Looked up case-insensitively by URL host before the global setting is
    /// consulted, so e.g. `example.com` can be forced to always open in-app
    /// while every other host still goes through the dialog.
    public var browserDomainRules: [BrowserDomainRule] = [] {
        didSet { saveBrowserDomainRules() }
    }

    /// Always open new in-app browser tabs on the split-view right pane
    /// (issue #498). Off by default; when enabled, terminal links resolved to
    /// in-app tabs land on the right side.
    public var alwaysOpenLinksInSplit: Bool = Defaults.alwaysOpenLinksInSplit {
        didSet { preferences.setBool(alwaysOpenLinksInSplit, Keys.alwaysOpenLinksInSplit) }
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

    /// Whether to close the tmux pane when Claude exits normally (user typed /exit or ctrl+c at prompt)
    public var closePaneOnSessionEnd: Bool = Defaults.closePaneOnSessionEnd {
        didSet { preferences.setBool(closePaneOnSessionEnd, Keys.closePaneOnSessionEnd) }
    }

    /// Path to claude command (for auto-run in project folders).
    ///
    /// Deprecated: per-plugin settings live in
    /// `~/.gallager/state/plugins/<id>/settings.json` (Task 16). This
    /// property is kept temporarily so the legacy `commandPath(for:)`
    /// helpers still work for callers that haven't migrated to
    /// `PluginManager.commandForLaunch(...)`. Task 21 deletes it.
    @available(*, deprecated, message: "Use per-plugin settings via PluginManager.commandForLaunch")
    public var claudeCommandPath: String = Defaults.claudeCommandPath {
        didSet { preferences.setString(claudeCommandPath, Keys.claudeCommandPath) }
    }

    /// Path to codex command (for auto-run in Codex project folders).
    ///
    /// Deprecated: see `claudeCommandPath`'s note. Removed in Task 21.
    @available(*, deprecated, message: "Use per-plugin settings via PluginManager.commandForLaunch")
    public var codexCommandPath: String = Defaults.codexCommandPath {
        didSet { preferences.setString(codexCommandPath, Keys.codexCommandPath) }
    }

    /// Whether to automatically run `codex` when creating a session in a
    /// Codex project folder. Defaults to true; mirrors
    /// `autoRunClaudeInProjects` so per-session opt-out stays possible.
    public var autoRunCodexInProjects: Bool = Defaults.autoRunCodexInProjects {
        didSet { preferences.setBool(autoRunCodexInProjects, Keys.autoRunCodexInProjects) }
    }

    /// Resolves the command path for a given coding agent.
    public func commandPath(for agent: CodingAgent) -> String {
        commandPath(forPluginID: agent.rawValue) ?? ""
    }

    /// Resolves the command path for a plugin id (Spec §11). Returns `nil`
    /// when the plugin id isn't recognised — the caller decides whether to
    /// fall back to a bare-shell spawn or surface an error.
    ///
    /// `CodingAgent.rawValue` ("claude-code", "codex") matches the plugin
    /// ids bundled with the app, so this method works for both the legacy
    /// `CodingAgent` callers and any new plugin-id-driven path. Plugins
    /// installed via a third-party manifest fall through to `nil`; the new
    /// `PluginManager.commandForLaunch` RPC is the proper resolver for
    /// those.
    public func commandPath(forPluginID pluginID: String) -> String? {
        switch pluginID {
        case CodingAgent.claudeCode.rawValue: claudeCommandPath
        case CodingAgent.codex.rawValue: codexCommandPath
        default: nil
        }
    }

    /// Whether the user wants `start a session in a project folder` to
    /// auto-run the agent's CLI. Sourced from the legacy per-agent toggles;
    /// Task 16 replaces this with per-plugin settings.
    public func autoRunInProjects(forPluginID pluginID: String) -> Bool {
        switch pluginID {
        case CodingAgent.claudeCode.rawValue: autoRunClaudeInProjects
        case CodingAgent.codex.rawValue: autoRunCodexInProjects
        default: false
        }
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

    // MARK: - Project Scanning Settings

    /// Additional directories to scan for Claude projects (each should contain .claude.json and .claude/projects/)
    public var additionalClaudeFolders: [String] = [] {
        didSet { saveAdditionalClaudeFolders() }
    }

    // MARK: - External Editor Settings

    /// External editors the user can pick to open files with.
    ///
    /// On first launch this is empty; ``seedEditorsIfEmpty(using:)`` populates
    /// it with the installed editors from ``EditorClient/detectInstalledKnownEditors``.
    public var editors: [EditorConfiguration] = [] {
        didSet { saveEditors() }
    }

    /// Whether we've already attempted the first-launch editor seeding. Persisted
    /// so we don't re-seed an empty list when the user has explicitly removed all
    /// of them.
    public var hasSeededEditors: Bool = Defaults.hasSeededEditors {
        didSet { preferences.setBool(hasSeededEditors, Keys.hasSeededEditors) }
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
        self.appearanceMode = AppearanceMode(rawValue: preferences.string(Keys.appearanceMode) ?? "") ?? Defaults.appearanceMode
        self.openPanesWindowOnLaunch = preferences.optionalBool(Keys.openPanesWindowOnLaunch) ?? Defaults.openPanesWindowOnLaunch
        self.showStatusBar = preferences.optionalBool(Keys.showStatusBar) ?? Defaults.showStatusBar
        self.autoReconnect = preferences.optionalBool(Keys.autoReconnect) ?? Defaults.autoReconnect
        self.preventSleepDuringSessions = preferences.optionalBool(Keys.preventSleepDuringSessions) ?? Defaults.preventSleepDuringSessions
        self.autoCopyOnSelect = preferences.optionalBool(Keys.autoCopyOnSelect) ?? Defaults.autoCopyOnSelect
        self.alwaysAutoResize = preferences.optionalBool(Keys.alwaysAutoResize) ?? Defaults.alwaysAutoResize
        self.openClickedFileInNewTab = preferences.optionalBool(Keys.openClickedFileInNewTab) ?? Defaults.openClickedFileInNewTab
        self.alwaysOpenFilesInSplit = preferences.optionalBool(Keys.alwaysOpenFilesInSplit) ?? Defaults.alwaysOpenFilesInSplit
        self.browserLinkBehavior = BrowserLinkBehavior(
            rawValue: preferences.string(Keys.browserLinkBehavior) ?? ""
        ) ?? Defaults.browserLinkBehavior
        self.browserDomainRules = Self.loadCodable(from: preferences, key: Keys.browserDomainRules)
        self.alwaysOpenLinksInSplit = preferences.optionalBool(Keys.alwaysOpenLinksInSplit) ?? Defaults.alwaysOpenLinksInSplit
        self.reconnectDelay = preferences.optionalInt(Keys.reconnectDelay) ?? Defaults.reconnectDelay
        self.tmuxPath = preferences.string(Keys.tmuxPath) ?? Defaults.tmuxPath
        self.tmuxSocket = preferences.string(Keys.tmuxSocket) ?? Defaults.tmuxSocket

        // Claude command settings
        self.autoRunClaudeInProjects = preferences.optionalBool(Keys.autoRunClaudeInProjects) ?? Defaults.autoRunClaudeInProjects
        self.closePaneOnSessionEnd = preferences.optionalBool(Keys.closePaneOnSessionEnd) ?? Defaults.closePaneOnSessionEnd
        self.claudeCommandPath = preferences.string(Keys.claudeCommandPath) ?? Defaults.claudeCommandPath
        self.codexCommandPath = preferences.string(Keys.codexCommandPath) ?? Defaults.codexCommandPath
        self.autoRunCodexInProjects = preferences.optionalBool(Keys.autoRunCodexInProjects) ?? Defaults.autoRunCodexInProjects
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

        // Project Scanning
        self.additionalClaudeFolders = Self.loadCodable(from: preferences, key: Keys.additionalClaudeFolders)

        // External Editors
        self.editors = Self.loadCodable(from: preferences, key: Keys.editors)
        self.hasSeededEditors = preferences.optionalBool(Keys.hasSeededEditors) ?? Defaults.hasSeededEditors

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
        case appearanceMode
        case openPanesWindowOnLaunch
        case showStatusBar
        case autoReconnect
        case preventSleepDuringSessions
        case autoCopyOnSelect
        case alwaysAutoResize
        case openClickedFileInNewTab
        case alwaysOpenFilesInSplit
        case browserLinkBehavior
        case browserDomainRules
        case alwaysOpenLinksInSplit
        case reconnectDelay
        case tmuxPath
        case tmuxSocket
        case autoRunClaudeInProjects
        case claudeCommandPath
        case codexCommandPath
        case autoRunCodexInProjects
        case closePaneOnSessionEnd
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
        /// Project Scanning
        case additionalClaudeFolders
        /// External Editors
        case editors
        case hasSeededEditors
        /// Plugin
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
        static let appearanceMode = AppearanceMode.system
        static let openPanesWindowOnLaunch = true
        static let showStatusBar = true
        static let autoReconnect = true
        static let preventSleepDuringSessions = true
        static let autoCopyOnSelect = true
        static let alwaysAutoResize = true
        static let openClickedFileInNewTab = true
        static let alwaysOpenFilesInSplit = false
        static let browserLinkBehavior = BrowserLinkBehavior.ask
        static let alwaysOpenLinksInSplit = false
        static let reconnectDelay = 2
        static let tmuxPath = "/opt/homebrew/bin/tmux"
        static let tmuxSocket = ""
        static let autoRunClaudeInProjects = true
        static let claudeCommandPath = "claude"
        static let codexCommandPath = "codex"
        static let autoRunCodexInProjects = true
        static let closePaneOnSessionEnd = false
        static let terminalApp = TerminalApp.terminalApp
        static let customTerminalPath = ""
        // Remote Access
        static let externalServerURL = "wss://claudespy.gustavo.eng.br"
        static let autoConnectToServer = true
        /// External Editors
        static let hasSeededEditors = false
        /// Plugin
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

    private func saveAdditionalClaudeFolders() {
        guard let data = try? JSONEncoder().encode(additionalClaudeFolders) else {
            return
        }
        preferences.setData(data, Keys.additionalClaudeFolders)
    }

    private func saveEditors() {
        guard let data = try? JSONEncoder().encode(editors) else {
            return
        }
        preferences.setData(data, Keys.editors)
    }

    private func saveSidebarTerminalFields() {
        guard let data = try? JSONEncoder().encode(sidebarTerminalFields) else {
            return
        }
        preferences.setData(data, Keys.sidebarTerminalFields)
    }

    private func saveBrowserDomainRules() {
        guard let data = try? JSONEncoder().encode(browserDomainRules) else {
            return
        }
        preferences.setData(data, Keys.browserDomainRules)
    }

    // MARK: - Browser Domain Rule Management

    /// Returns the per-domain behavior for `url` if one exists.
    ///
    /// Host matching is case-insensitive and uses the URL's host verbatim — no
    /// suffix matching, so a rule for `example.com` does not cover
    /// `sub.example.com`. When the URL carries an explicit port the lookup key
    /// is `host:port`, so a rule for `example.com:8080` matches only that
    /// host+port combination and a port-less rule for `example.com` matches
    /// only URLs without an explicit port.
    public func browserBehavior(for url: URL) -> BrowserLinkBehavior? {
        guard let host = url.host?.lowercased() else { return nil }
        let key = url.port.map { "\(host):\($0)" } ?? host
        return browserDomainRules.first(where: { $0.domain == key })?.behavior
    }

    /// Sets the behavior for `domain`, replacing any existing rule for the
    /// same (case-insensitively normalized) host.
    public func setBrowserBehavior(_ behavior: BrowserLinkBehavior, for domain: String) {
        let normalized = domain.lowercased()
        guard !normalized.isEmpty else { return }
        if let index = browserDomainRules.firstIndex(where: { $0.domain == normalized }) {
            browserDomainRules[index].behavior = behavior
        } else {
            browserDomainRules.append(BrowserDomainRule(domain: normalized, behavior: behavior))
        }
    }

    /// Updates a rule's behavior in place, looked up by `id`. No-op if not
    /// found.
    public func updateBrowserDomainRule(id: UUID, behavior: BrowserLinkBehavior) {
        if let index = browserDomainRules.firstIndex(where: { $0.id == id }) {
            browserDomainRules[index].behavior = behavior
        }
    }

    /// Removes a per-domain rule by id.
    public func removeBrowserDomainRule(id: UUID) {
        browserDomainRules.removeAll { $0.id == id }
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

    // MARK: - Claude Folder Management

    /// Add a new folder to scan for Claude projects.
    ///
    /// Returns the normalized path that was added (or would have been added if
    /// it hadn't already been present). Callers that need to act on the
    /// canonical representation can use this instead of re-normalizing the
    /// input.
    @discardableResult
    public func addClaudeFolder(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !additionalClaudeFolders.contains(normalized) else { return normalized }
        additionalClaudeFolders.append(normalized)
        return normalized
    }

    /// Remove a Claude folder by its path.
    public func removeClaudeFolder(_ path: String) {
        additionalClaudeFolders.removeAll { $0 == path }
    }

    // MARK: - Editor Management

    /// Adds an editor to the list. Returns the added editor.
    @discardableResult
    public func addEditor(_ editor: EditorConfiguration) -> EditorConfiguration {
        editors.append(editor)
        return editor
    }

    /// Removes an editor by its identifier.
    public func removeEditor(id: UUID) {
        editors.removeAll { $0.id == id }
    }

    /// Updates an existing editor in place. Looked up by `id`; no-op if not found.
    public func updateEditor(_ editor: EditorConfiguration) {
        if let index = editors.firstIndex(where: { $0.id == editor.id }) {
            editors[index] = editor
        }
    }

    /// On first launch (or when the user explicitly hasn't seeded yet), populate
    /// `editors` with the editors that are currently installed on the host.
    /// Subsequent calls are no-ops because `hasSeededEditors` is set to true.
    ///
    /// Async because the live `detectInstalledKnownEditors` runs Launch
    /// Services lookups off the MainActor.
    public func seedEditorsIfEmpty(using client: EditorClient) async {
        guard !hasSeededEditors else { return }
        if editors.isEmpty {
            editors = await client.detectInstalledKnownEditors()
        }
        hasSeededEditors = true
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
