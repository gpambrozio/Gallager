#if os(iOS)
    import Foundation

    /// Represents a paired Mac server with all connection details.
    ///
    /// Each Mac server paired with the iOS app has its own unique `pairId`,
    /// cryptographic keys for E2EE, and connection state.
    public struct PairedMac: Codable, Identifiable, Sendable, Hashable {
        // MARK: - Properties

        /// Unique pair identifier (also serves as Identifiable id)
        public let id: String

        /// Display name of the Mac device
        public let macName: String

        /// Partner's (Mac's) public key for E2EE (Base64-encoded)
        public let partnerPublicKey: String

        /// Partner's (Mac's) public key ID for E2EE
        public let partnerPublicKeyId: String

        /// When this pairing was established
        public let pairedAt: Date

        /// Optional custom name set by user for this Mac
        public var customName: String?

        // MARK: - Computed Properties

        /// Display name for UI (custom name if set, otherwise Mac name)
        public var displayName: String {
            customName ?? macName
        }

        // MARK: - Initialization

        public init(
            id: String,
            macName: String,
            partnerPublicKey: String,
            partnerPublicKeyId: String,
            pairedAt: Date = Date(),
            customName: String? = nil
        ) {
            self.id = id
            self.macName = macName
            self.partnerPublicKey = partnerPublicKey
            self.partnerPublicKeyId = partnerPublicKeyId
            self.pairedAt = pairedAt
            self.customName = customName
        }
    }
#endif
