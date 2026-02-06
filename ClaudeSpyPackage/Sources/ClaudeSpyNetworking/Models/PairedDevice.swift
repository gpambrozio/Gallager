import Foundation

/// Protocol for paired device models, unifying `PairedHost` (macOS) and `PairedMac` (iOS).
///
/// Both platforms maintain a list of paired devices with identical structure but
/// platform-specific property names (`hostName` vs `macName`). This protocol
/// provides a common interface for shared code like `ViewerRelayClient` and
/// `ViewerConnection`.
public protocol ViewerPairedDevice: Codable, Identifiable, Sendable, Hashable where ID == String {
    /// Unique pair identifier
    var id: String { get }

    /// Display name of the paired device (maps to `hostName` or `macName`)
    var deviceName: String { get }

    /// Username of the device's user
    var username: String { get }

    /// Partner's public key for E2EE (Base64-encoded)
    var partnerPublicKey: String { get }

    /// Partner's public key ID for E2EE
    var partnerPublicKeyId: String { get }

    /// When this pairing was established
    var pairedAt: Date { get }

    /// Optional custom name set by user
    var customName: String? { get set }

    /// Display name for UI (custom name if set, otherwise device name)
    var displayName: String { get }

    /// Display name including username if available (for disambiguation)
    func displayName(showUsername: Bool) -> String
}

// MARK: - Default Implementations

public extension ViewerPairedDevice {
    var displayName: String {
        customName ?? deviceName
    }

    func displayName(showUsername: Bool) -> String {
        if let custom = customName {
            return custom
        }
        if showUsername {
            return "\(deviceName) (\(username))"
        }
        return deviceName
    }
}
