import Foundation

/// Represents a paired Mac host that a viewer device connects to.
///
/// Used by both iOS and macOS viewer apps. Each paired host has its own
/// unique `pairId`, cryptographic keys for E2EE, and connection state.
public struct PairedHost: Codable, Identifiable, Sendable, Hashable {
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

    /// Display name for UI (custom name if set, otherwise host name)
    public var displayName: String {
        customName ?? hostName
    }

    /// Display name including username if available (for disambiguation)
    /// - Parameter showUsername: Whether to append username in parentheses
    /// - Returns: The display name, optionally with username suffix
    public func displayName(showUsername: Bool) -> String {
        if let custom = customName {
            return custom
        }
        if showUsername {
            return "\(hostName) (\(username))"
        }
        return hostName
    }

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
