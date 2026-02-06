import ClaudeSpyNetworking
import Foundation

/// Represents a paired Mac host that this Mac can connect to as a viewer.
///
/// Each Mac host paired with this Mac has its own unique `pairId`,
/// cryptographic keys for E2EE, and connection state. This is the Mac-side
/// equivalent of `PairedMac` on iOS.
public struct PairedHost: ViewerPairedDevice {
    // MARK: - Properties

    /// Unique pair identifier (also serves as Identifiable id)
    public let id: String

    /// Display name of the host Mac
    public let hostName: String

    /// Username of the host Mac user (e.g., "john")
    public let username: String

    /// Partner's (host's) public key for E2EE (Base64-encoded)
    public let partnerPublicKey: String

    /// Partner's (host's) public key ID for E2EE
    public let partnerPublicKeyId: String

    /// When this pairing was established
    public let pairedAt: Date

    /// Optional custom name set by user for this host
    public var customName: String?

    // MARK: - Computed Properties

    /// Device name for the `ViewerPairedDevice` protocol (maps to `hostName`)
    public var deviceName: String { hostName }

    // MARK: - Initialization

    public init(
        id: String,
        hostName: String,
        username: String,
        partnerPublicKey: String,
        partnerPublicKeyId: String,
        pairedAt: Date = Date(),
        customName: String? = nil
    ) {
        self.id = id
        self.hostName = hostName
        self.username = username
        self.partnerPublicKey = partnerPublicKey
        self.partnerPublicKeyId = partnerPublicKeyId
        self.pairedAt = pairedAt
        self.customName = customName
    }
}
