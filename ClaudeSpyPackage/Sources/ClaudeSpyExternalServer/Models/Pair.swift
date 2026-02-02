import Foundation

/// Represents a paired Mac and iOS device
struct Pair: Sendable, Codable {
    /// Unique identifier for this pairing
    let id: String

    /// Mac device identifier
    let macDeviceId: String

    /// Mac device display name
    let macDeviceName: String

    /// Mac username (e.g., "john")
    var macUsername: String

    /// Mac public key for E2EE (Base64-encoded)
    /// Mutable to allow key updates on reconnection
    var macPublicKey: String

    /// Mac public key identifier
    var macPublicKeyId: String

    /// iOS device identifier
    let iosDeviceId: String

    /// iOS device display name
    let iosDeviceName: String

    /// iOS public key for E2EE (Base64-encoded)
    /// Mutable to allow key updates on reconnection
    var iosPublicKey: String

    /// iOS public key identifier
    var iosPublicKeyId: String

    /// When the pairing was created
    let createdAt: Date

    /// iOS push notification token (optional, registered when iOS connects)
    var pushToken: String?
}
