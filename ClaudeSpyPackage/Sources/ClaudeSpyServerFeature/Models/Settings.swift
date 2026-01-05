import Foundation
import SwiftUI

/// Application settings with persistent storage
@Observable
@MainActor
public final class AppSettings: Sendable {
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

    /// Delay before attempting reconnection (in seconds)
    public var reconnectDelay: Int {
        didSet { UserDefaults.standard.set(reconnectDelay, forKey: Keys.reconnectDelay) }
    }

    // MARK: - tmux Settings

    /// Path to tmux binary
    public var tmuxPath: String {
        didSet { UserDefaults.standard.set(tmuxPath, forKey: Keys.tmuxPath) }
    }

    /// tmux socket path (empty for default)
    public var tmuxSocket: String {
        didSet { UserDefaults.standard.set(tmuxSocket, forKey: Keys.tmuxSocket) }
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

    /// Whether to automatically connect to relay server on launch
    public var autoConnectToServer: Bool {
        didSet { UserDefaults.standard.set(autoConnectToServer, forKey: Keys.autoConnectToServer) }
    }

    /// Unique device identifier for this Mac (generated on first launch)
    public var deviceId: String {
        didSet { UserDefaults.standard.set(deviceId, forKey: Keys.deviceId) }
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
        self.reconnectDelay = defaults.object(forKey: Keys.reconnectDelay) as? Int ?? Defaults.reconnectDelay
        self.tmuxPath = defaults.string(forKey: Keys.tmuxPath) ?? Defaults.tmuxPath
        self.tmuxSocket = defaults.string(forKey: Keys.tmuxSocket) ?? Defaults.tmuxSocket

        // Remote Access
        self.externalServerURL = defaults.string(forKey: Keys.externalServerURL) ?? Defaults.externalServerURL
        self.pairId = defaults.string(forKey: Keys.pairId)
        self.pairedDeviceName = defaults.string(forKey: Keys.pairedDeviceName)
        self.autoConnectToServer = defaults.object(forKey: Keys.autoConnectToServer) as? Bool ?? Defaults.autoConnectToServer

        // Generate device ID if not already set
        if let existingDeviceId = defaults.string(forKey: Keys.deviceId) {
            self.deviceId = existingDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            self.deviceId = newDeviceId
            defaults.set(newDeviceId, forKey: Keys.deviceId)
        }
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
        static let reconnectDelay = "reconnectDelay"
        static let tmuxPath = "tmuxPath"
        static let tmuxSocket = "tmuxSocket"
        // Remote Access
        static let externalServerURL = "externalServerURL"
        static let pairId = "pairId"
        static let pairedDeviceName = "pairedDeviceName"
        static let autoConnectToServer = "autoConnectToServer"
        static let deviceId = "deviceId"
    }

    // MARK: - Defaults

    private enum Defaults {
        static let fontName = "SF Mono"
        static let fontSize = 12.0
        static let scrollbackLines = 10000
        static let theme = TerminalTheme.defaultDark
        static let restoreWindowsOnLaunch = true
        static let showStatusBar = true
        static let autoReconnect = false
        static let reconnectDelay = 5
        static let tmuxPath = "/opt/homebrew/bin/tmux"
        static let tmuxSocket = ""
        // Remote Access
        static let externalServerURL = "wss://claudespy.gustavo.eng.br"
        static let autoConnectToServer = true
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
    }
}

// MARK: - Terminal Theme

public enum TerminalTheme: String, CaseIterable, Sendable {
    case defaultDark = "Default Dark"
    case defaultLight = "Default Light"
    case solarizedDark = "Solarized Dark"
    case solarizedLight = "Solarized Light"
}
