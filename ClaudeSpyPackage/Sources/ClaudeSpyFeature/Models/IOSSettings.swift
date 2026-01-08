import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Settings for the ClaudeSpy iOS app with UserDefaults persistence.
@Observable
@MainActor
final public class IOSSettings {
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let deviceId = "deviceId"
        static let pairId = "pairId"
        static let pairedMacName = "pairedMacName"
        static let externalServerURL = "externalServerURL"
        static let autoReconnect = "autoReconnect"
        static let terminalFontName = "terminalFontName"
        static let terminalFontSize = "terminalFontSize"
    }

    // MARK: - Singleton

    public static let shared = IOSSettings()

    // MARK: - Properties

    /// Unique device identifier (generated once and persisted)
    public var deviceId: String {
        didSet { UserDefaults.standard.set(deviceId, forKey: Keys.deviceId) }
    }

    /// The pair ID from successful device pairing
    public var pairId: String? {
        didSet { UserDefaults.standard.set(pairId, forKey: Keys.pairId) }
    }

    /// Name of the paired Mac device
    public var pairedMacName: String? {
        didSet { UserDefaults.standard.set(pairedMacName, forKey: Keys.pairedMacName) }
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

    // MARK: - Computed Properties

    /// Whether the device is currently paired
    public var isPaired: Bool {
        pairId != nil
    }

    /// The display name for this iOS device
    public var deviceName: String {
        #if os(iOS)
            UIDevice.current.name
        #else
            Host.current().localizedName ?? "Device"
        #endif
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

        // Load other settings
        self.pairId = defaults.string(forKey: Keys.pairId)
        self.pairedMacName = defaults.string(forKey: Keys.pairedMacName)
        self.externalServerURL = defaults.string(forKey: Keys.externalServerURL)
            ?? "wss://claudespy.gustavo.eng.br"
        self.autoReconnect = defaults.bool(forKey: Keys.autoReconnect)

        // Terminal settings with iOS-appropriate defaults
        self.terminalFontName = defaults.string(forKey: Keys.terminalFontName) ?? "Menlo"
        // swiftlint:disable:next custom_no_number_decimals
        self.terminalFontSize = defaults.object(forKey: Keys.terminalFontSize) as? Double ?? 10.0
    }

    // MARK: - Methods

    /// Clear all pairing data
    public func clearPairing() {
        pairId = nil
        pairedMacName = nil
    }

    /// Save pairing information
    public func savePairing(pairId: String, macName: String?) {
        self.pairId = pairId
        pairedMacName = macName
    }
}
