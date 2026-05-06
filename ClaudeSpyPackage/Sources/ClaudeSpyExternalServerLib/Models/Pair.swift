import Foundation

/// Represents a paired host and viewer device
struct Pair: Codable {
    /// Unique identifier for this pairing
    let id: String

    /// Host device identifier
    let hostDeviceId: String

    /// Host device display name.
    /// Mutable so the host can change its display name without re-pairing.
    var hostDeviceName: String

    /// Host username (e.g., "john")
    var hostUsername: String

    /// Host public key for E2EE (Base64-encoded)
    /// Mutable to allow key updates on reconnection
    var hostPublicKey: String

    /// Host public key identifier
    var hostPublicKeyId: String

    /// Viewer device identifier
    let viewerDeviceId: String

    /// Viewer device display name.
    /// Mutable so the user can rename their iOS device on the iOS settings
    /// screen and have the host pick up the new name without re-pairing.
    var viewerDeviceName: String

    /// Viewer public key for E2EE (Base64-encoded)
    /// Mutable to allow key updates on reconnection
    var viewerPublicKey: String

    /// Viewer public key identifier
    var viewerPublicKeyId: String

    /// When the pairing was created
    let createdAt: Date

    /// Viewer push notification token (optional, registered when iOS viewer connects)
    var pushToken: String?
}
