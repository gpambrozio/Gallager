#if os(iOS)
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
            static let pairedMacs = "pairedMacs"
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

        /// All paired Mac servers
        public private(set) var pairedMacs: [PairedMac] = [] {
            didSet { savePairedMacs() }
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

        /// Whether at least one Mac is paired
        public var isPaired: Bool {
            !pairedMacs.isEmpty
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

            // Load paired Macs (or migrate from legacy format)
            self.pairedMacs = loadPairedMacs()
        }

        // MARK: - Paired Macs Storage

        private func loadPairedMacs() -> [PairedMac] {
            guard let data = UserDefaults.standard.data(forKey: Keys.pairedMacs) else {
                return []
            }

            do {
                return try JSONDecoder().decode([PairedMac].self, from: data)
            } catch {
                // Corrupted data, start fresh
                return []
            }
        }

        private func savePairedMacs() {
            guard let data = try? JSONEncoder().encode(pairedMacs) else {
                return
            }
            UserDefaults.standard.set(data, forKey: Keys.pairedMacs)
        }

        // MARK: - Pairing Management

        /// Add a new paired Mac
        public func addPairing(_ mac: PairedMac) {
            // Remove any existing pairing with same ID (update case)
            pairedMacs.removeAll { $0.id == mac.id }
            pairedMacs.append(mac)
        }

        /// Remove a paired Mac by ID
        public func removePairing(id: String) {
            pairedMacs.removeAll { $0.id == id }
        }

        /// Get a paired Mac by ID
        public func getPairing(id: String) -> PairedMac? {
            pairedMacs.first { $0.id == id }
        }

        /// Update a paired Mac (e.g., custom name)
        public func updatePairing(_ mac: PairedMac) {
            if let index = pairedMacs.firstIndex(where: { $0.id == mac.id }) {
                pairedMacs[index] = mac
            }
        }

        /// Clear all pairings
        public func clearAllPairings() {
            pairedMacs = []
        }

        // MARK: - Display Helpers

        /// Check if a Mac's name is duplicated among paired Macs.
        ///
        /// Use this to determine whether to show the username for disambiguation.
        /// - Parameter mac: The Mac to check
        /// - Returns: True if another paired Mac has the same macName
        public func hasDuplicateMacName(for mac: PairedMac) -> Bool {
            pairedMacs.contains { $0.id != mac.id && $0.macName == mac.macName }
        }
    }
#endif
