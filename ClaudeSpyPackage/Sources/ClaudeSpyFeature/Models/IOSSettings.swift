import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Settings for the ClaudeSpy iOS app with UserDefaults persistence.
@Observable
@MainActor
public final class IOSSettings: Sendable {
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let deviceId = "deviceId"
        static let pairId = "pairId"
        static let pairedMacName = "pairedMacName"
        static let externalServerURL = "externalServerURL"
        static let autoReconnect = "autoReconnect"
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
            deviceId = savedDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            defaults.set(newDeviceId, forKey: Keys.deviceId)
            deviceId = newDeviceId
        }

        // Load other settings
        pairId = defaults.string(forKey: Keys.pairId)
        pairedMacName = defaults.string(forKey: Keys.pairedMacName)
        externalServerURL = defaults.string(forKey: Keys.externalServerURL)
            ?? "wss://claudespy.gustavo.eng.br"
        autoReconnect = defaults.bool(forKey: Keys.autoReconnect)
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
