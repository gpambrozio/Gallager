import Foundation

/// Represents a paired Mac and iOS device
struct Pair: Sendable {
    /// Unique identifier for this pairing
    let id: String

    /// Mac device identifier
    let macDeviceId: String

    /// Mac device display name
    let macDeviceName: String

    /// iOS device identifier
    let iosDeviceId: String

    /// iOS device display name
    let iosDeviceName: String

    /// When the pairing was created
    let createdAt: Date
}
