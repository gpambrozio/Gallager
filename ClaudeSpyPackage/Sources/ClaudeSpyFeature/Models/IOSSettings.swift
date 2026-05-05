#if os(iOS)
    import ClaudeSpyCommon
    import Dependencies
    import Foundation
    import SwiftUI
    import UIKit

    // MARK: - PreferencesService + AppSettings.Keys

    extension PreferencesService {
        func string(_ key: IOSSettings.Keys) -> String? { string(key.rawValue) }
        func setString(_ value: String?, _ key: IOSSettings.Keys) { setString(value, key.rawValue) }
        func optionalBool(_ key: IOSSettings.Keys) -> Bool? { optionalBool(key.rawValue) }
        func setBool(_ value: Bool, _ key: IOSSettings.Keys) { setBool(value, key.rawValue) }
        func optionalInt(_ key: IOSSettings.Keys) -> Int? { optionalInt(key.rawValue) }
        func setInt(_ value: Int, _ key: IOSSettings.Keys) { setInt(value, key.rawValue) }
        func optionalDouble(_ key: IOSSettings.Keys) -> Double? { optionalDouble(key.rawValue) }
        func setDouble(_ value: Double, _ key: IOSSettings.Keys) { setDouble(value, key.rawValue) }
        func data(_ key: IOSSettings.Keys) -> Data? { data(key.rawValue) }
        func setData(_ value: Data?, _ key: IOSSettings.Keys) { setData(value, key.rawValue) }
    }

    /// Settings for the ClaudeSpy iOS app with UserDefaults persistence.
    @Observable
    @MainActor
    final public class IOSSettings {
        // MARK: - UserDefaults Keys

        public enum Keys: String {
            case deviceId
            case pairedHosts
            case externalServerURL
            case autoReconnect
            case appearanceMode
            case terminalFontName
            case terminalFontSize
            case newSessionName
            case newSessionWidth
            case newSessionHeight
        }

        // MARK: - Dependencies

        /// Preferences service for persistent storage
        @ObservationIgnored
        @Dependency(PreferencesService.self) private var preferences

        // MARK: - Properties

        /// Unique device identifier (generated once and persisted)
        public var deviceId = "" {
            didSet { preferences.setString(deviceId, Keys.deviceId) }
        }

        /// All paired host servers
        public private(set) var pairedHosts: [PairedHost] = [] {
            didSet { savePairedHosts() }
        }

        /// External relay server URL
        public var externalServerURL = "" {
            didSet { preferences.setString(externalServerURL, Keys.externalServerURL) }
        }

        /// Whether to automatically reconnect on app launch
        public var autoReconnect = false {
            didSet { preferences.setBool(autoReconnect, Keys.autoReconnect) }
        }

        /// App appearance (System / Light / Dark). Drives
        /// `.preferredColorScheme(_:)` on the iOS root view.
        public var appearanceMode: AppearanceMode = .system {
            didSet { preferences.setString(appearanceMode.rawValue, Keys.appearanceMode) }
        }

        /// Font name for terminal snapshot display
        public var terminalFontName = "Menlo" {
            didSet { preferences.setString(terminalFontName, Keys.terminalFontName) }
        }

        /// Font size for terminal snapshot display
        public var terminalFontSize: Double = 10 {
            didSet { preferences.setDouble(terminalFontSize, Keys.terminalFontSize) }
        }

        /// Base name for new tmux sessions created from iOS
        public var newSessionName = "claude" {
            didSet { preferences.setString(newSessionName, Keys.newSessionName) }
        }

        /// Width (columns) for new tmux sessions
        public var newSessionWidth = 120 {
            didSet { preferences.setInt(newSessionWidth, Keys.newSessionWidth) }
        }

        /// Height (rows) for new tmux sessions
        public var newSessionHeight = 40 {
            didSet { preferences.setInt(newSessionHeight, Keys.newSessionHeight) }
        }

        // MARK: - Computed Properties

        /// Whether at least one host is paired
        public var isPaired: Bool {
            !pairedHosts.isEmpty
        }

        /// The display name for this iOS device
        public var deviceName: String {
            UIDevice.current.name
        }

        // MARK: - Initialization

        /// Create a single instance at the app root and propagate via `.environment()`.
        /// Multiple instances share the same UserDefaults backing store but maintain
        /// independent `@Observable` state — mutations on one instance will not
        /// trigger observation updates on another.
        public init() {
            // Load or generate device ID
            if let savedDeviceId = preferences.string(Keys.deviceId) {
                self.deviceId = savedDeviceId
            } else {
                let newDeviceId = UUID().uuidString
                preferences.setString(newDeviceId, Keys.deviceId)
                self.deviceId = newDeviceId
            }

            // Load settings
            self.externalServerURL = preferences.string(Keys.externalServerURL)
                ?? "wss://claudespy.gustavo.eng.br"
            self.autoReconnect = preferences.optionalBool(Keys.autoReconnect) ?? false
            self.appearanceMode = AppearanceMode(rawValue: preferences.string(Keys.appearanceMode) ?? "") ?? .system

            // Terminal settings with iOS-appropriate defaults
            self.terminalFontName = preferences.string(Keys.terminalFontName) ?? "Menlo"
            self.terminalFontSize = preferences.optionalDouble(Keys.terminalFontSize) ?? 10

            // New session settings
            self.newSessionName = preferences.string(Keys.newSessionName) ?? "claude"
            self.newSessionWidth = preferences.optionalInt(Keys.newSessionWidth) ?? 120
            self.newSessionHeight = preferences.optionalInt(Keys.newSessionHeight) ?? 40

            // Load paired hosts
            self.pairedHosts = loadPairedHosts()
        }

        // MARK: - Paired Hosts Storage

        private func loadPairedHosts() -> [PairedHost] {
            guard let data = preferences.data(Keys.pairedHosts) else {
                return []
            }

            do {
                return try JSONDecoder().decode([PairedHost].self, from: data)
            } catch {
                // Corrupted data, start fresh
                return []
            }
        }

        private func savePairedHosts() {
            guard let data = try? JSONEncoder().encode(pairedHosts) else {
                return
            }
            preferences.setData(data, Keys.pairedHosts)
        }

        // MARK: - Pairing Management

        /// Add a new paired host
        public func addPairing(_ host: PairedHost) {
            // Remove any existing pairing with same ID (update case)
            pairedHosts.removeAll { $0.id == host.id }
            pairedHosts.append(host)
        }

        /// Remove a paired host by ID
        public func removePairing(id: String) {
            pairedHosts.removeAll { $0.id == id }
        }

        /// Get a paired host by ID
        public func getPairing(id: String) -> PairedHost? {
            pairedHosts.first { $0.id == id }
        }

        /// Update a paired host (e.g., custom name)
        public func updatePairing(_ host: PairedHost) {
            if let index = pairedHosts.firstIndex(where: { $0.id == host.id }) {
                pairedHosts[index] = host
            }
        }

        /// Clear all pairings
        public func clearAllPairings() {
            pairedHosts = []
        }

        // MARK: - Display Helpers

        /// Check if a host's name is duplicated among paired hosts.
        ///
        /// Use this to determine whether to show the username for disambiguation.
        /// - Parameter host: The host to check
        /// - Returns: True if another paired host has the same hostName
        public func hasDuplicateHostName(for host: PairedHost) -> Bool {
            pairedHosts.contains { $0.id != host.id && $0.hostName == host.hostName }
        }
    }
#endif
