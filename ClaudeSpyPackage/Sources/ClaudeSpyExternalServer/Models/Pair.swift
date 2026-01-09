import Foundation

/// Represents a paired Mac and iOS device
struct Pair: Sendable, Codable {
    /// Unique identifier for this pairing
    let id: String

    /// Mac device identifier
    let macDeviceId: String

    /// Mac device display name
    let macDeviceName: String

    /// Mac public key for E2EE (Base64-encoded)
    let macPublicKey: String

    /// Mac public key identifier
    let macPublicKeyId: String

    /// iOS device identifier
    let iosDeviceId: String

    /// iOS device display name
    let iosDeviceName: String

    /// iOS public key for E2EE (Base64-encoded)
    let iosPublicKey: String

    /// iOS public key identifier
    let iosPublicKeyId: String

    /// When the pairing was created
    let createdAt: Date
}
