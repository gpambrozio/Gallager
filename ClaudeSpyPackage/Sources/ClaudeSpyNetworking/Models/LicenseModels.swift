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
