#if os(iOS)
    import ClaudeSpyCommon
    import Foundation
    import SwiftUI
    import UIKit

    /// Settings for the ClaudeSpy iOS app with UserDefaults persistence.
    @Observable
    @MainActor
    final public class IOSSettings {
        // MARK: - UserDefaults Keys

        private enum Keys {
            static let deviceId = "deviceId"
            static let pairedHosts = "pairedHosts"
            static let externalServerURL = "externalServerURL"
            static let autoReconnect = "autoReconnect"
            static let terminalFontName = "terminalFontName"
            static let terminalFontSize = "terminalFontSize"
            static let newSessionName = "newSessionName"
            static let newSessionWidth = "newSessionWidth"
            static let newSessionHeight = "newSessionHeight"
        }

        // MARK: - Singleton

        public static let shared = IOSSettings()

        // MARK: - Properties

        /// Unique device identifier (generated once and persisted)
        public var deviceId: String {
            didSet { UserDefaults.standard.set(deviceId, forKey: Keys.deviceId) }
        }

        /// All paired host servers
        public private(set) var pairedHosts: [PairedHost] = [] {
            didSet { savePairedHosts() }
        }

        /// External relay server URL
        public var externalServerURL: String {
            didSet { UserDefaults.standard.set(externalServerURL, forKey: Keys.externalServerURL) }
        }

        /// Whether to automatically reconnect on app launch
        public var autoReconnect: Bool {
            didSet { UserDefaults.standard.set(autoReconnect, forKey: Keys.autoReconnect) }
        }

        /// Font name for terminal snapshot display
        public var terminalFontName: String {
            didSet { UserDefaults.standard.set(terminalFontName, forKey: Keys.terminalFontName) }
        }

        /// Font size for terminal snapshot display
        public var terminalFontSize: Double {
            didSet { UserDefaults.standard.set(terminalFontSize, forKey: Keys.terminalFontSize) }
        }

        /// Base name for new tmux sessions created from iOS
        public var newSessionName: String {
            didSet { UserDefaults.standard.set(newSessionName, forKey: Keys.newSessionName) }
        }

        /// Width (columns) for new tmux sessions
        public var newSessionWidth: Int {
            didSet { UserDefaults.standard.set(newSessionWidth, forKey: Keys.newSessionWidth) }
        }

        /// Height (rows) for new tmux sessions
        public var newSessionHeight: Int {
            didSet { UserDefaults.standard.set(newSessionHeight, forKey: Keys.newSessionHeight) }
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

        private init() {
            let defaults = UserDefaults.standard

            // Load or generate device ID
            if let savedDeviceId = defaults.string(forKey: Keys.deviceId) {
                self.deviceId = savedDeviceId
            } else {
                let newDeviceId = UUID().uuidString
                defaults.set(newDeviceId, forKey: Keys.deviceId)
                self.deviceId = newDeviceId
            }

            // Load settings
            self.externalServerURL = defaults.string(forKey: Keys.externalServerURL)
                ?? "wss://claudespy.gustavo.eng.br"
            self.autoReconnect = defaults.bool(forKey: Keys.autoReconnect)

            // Terminal settings with iOS-appropriate defaults
            self.terminalFontName = defaults.string(forKey: Keys.terminalFontName) ?? "Menlo"
            // swiftlint:disable:next custom_no_number_decimals
            self.terminalFontSize = defaults.object(forKey: Keys.terminalFontSize) as? Double ?? 10.0

            // New session settings
            self.newSessionName = defaults.string(forKey: Keys.newSessionName) ?? "claude"
            self.newSessionWidth = defaults.object(forKey: Keys.newSessionWidth) as? Int ?? 120
            self.newSessionHeight = defaults.object(forKey: Keys.newSessionHeight) as? Int ?? 40

            // Load paired hosts
            self.pairedHosts = loadPairedHosts()
        }

        // MARK: - Paired Hosts Storage

        private func loadPairedHosts() -> [PairedHost] {
            guard let data = UserDefaults.standard.data(forKey: Keys.pairedHosts) else {
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
            UserDefaults.standard.set(data, forKey: Keys.pairedHosts)
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
