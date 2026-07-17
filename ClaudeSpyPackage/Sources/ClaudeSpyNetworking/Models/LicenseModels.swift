import Foundation

/// Request body for `POST /api/license/activate` on the relay.
public struct LicenseActivationRequest: Codable, Sendable {
    public let licenseKey: String
    public let deviceId: String
    public let deviceName: String

    public init(licenseKey: String, deviceId: String, deviceName: String) {
        self.licenseKey = licenseKey
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// Shape rules for Lemon Squeezy license keys, shared by the Mac app (to
/// pre-validate before a relay round-trip) and the relay (to clean keys
/// before hitting the LS API).
public enum LicenseKeyFormat {
    /// Keys copied from the LS receipt email carry wrap artifacts — embedded
    /// newlines/spaces and zero-width characters — that make LS respond
    /// "license_key not found". Strip whitespace and invisible format
    /// characters anywhere in the string, not just at the ends.
    public static func sanitized(_ raw: String) -> String {
        String(raw.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.properties.generalCategory != .format }
            .map(Character.init))
    }

    /// LS license keys are UUIDs; anything else is a paste mistake worth
    /// rejecting client-side before a server round-trip.
    public static func isValid(_ key: String) -> Bool {
        UUID(uuidString: key) != nil
    }
}

/// Billing state for one host device, returned by the relay's license endpoints.
public struct LicenseStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Device has never started a trial and has no license.
        case none
        /// In the free trial window; `expiresAt` is the trial end.
        case trial
        /// Active license key; `expiresAt` is the subscription expiry when known.
        case active
        /// Trial over or license lapsed/disabled.
        case expired
        /// This relay has licensing disabled (self-hosted); no subscription needed.
        case notRequired
    }

    public let state: State
    public let expiresAt: Date?
    public let activationLimit: Int?
    public let activationUsage: Int?

    public init(
        state: State,
        expiresAt: Date? = nil,
        activationLimit: Int? = nil,
        activationUsage: Int? = nil
    ) {
        self.state = state
        self.expiresAt = expiresAt
        self.activationLimit = activationLimit
        self.activationUsage = activationUsage
    }
}
