import Foundation

/// Current encryption protocol version
public let encryptionProtocolVersion = 1

/// Represents an encrypted payload that can be transmitted over the network.
///
/// The ciphertext contains the nonce, encrypted data, and authentication tag
/// combined by ChaChaPoly's sealed box format.
public struct EncryptedPayload: Codable, Sendable, Equatable {
    /// The encrypted ciphertext (nonce + encrypted data + auth tag)
    /// Encoded as Base64 for JSON transmission
    public let ciphertext: Data

    /// Identifies which public key was used for encryption.
    /// This allows the recipient to select the correct key for decryption
    /// if multiple keys exist (e.g., during key rotation).
    public let senderKeyId: String

    /// Protocol version for forward compatibility.
    /// If the version doesn't match, the recipient can reject or handle accordingly.
    public let version: Int

    public init(ciphertext: Data, senderKeyId: String, version: Int = encryptionProtocolVersion) {
        self.ciphertext = ciphertext
        self.senderKeyId = senderKeyId
        self.version = version
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case ciphertext
        case senderKeyId
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode ciphertext from Base64 string
        let base64String = try container.decode(String.self, forKey: .ciphertext)
        guard let data = Data(base64Encoded: base64String) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ciphertext,
                in: container,
                debugDescription: "Invalid Base64 string for ciphertext"
            )
        }
        self.ciphertext = data
        self.senderKeyId = try container.decode(String.self, forKey: .senderKeyId)
        self.version = try container.decode(Int.self, forKey: .version)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode ciphertext as Base64 string for JSON compatibility
        let base64String = ciphertext.base64EncodedString()
        try container.encode(base64String, forKey: .ciphertext)
        try container.encode(senderKeyId, forKey: .senderKeyId)
        try container.encode(version, forKey: .version)
    }
}

/// Wrapper for a stored key pair that can be persisted
public struct StoredKeyPair: Codable, Sendable {
    /// The raw private key bytes (32 bytes for Curve25519)
    public let privateKeyData: Data

    /// The raw public key bytes (32 bytes for Curve25519)
    public let publicKeyData: Data

    /// Unique identifier for this key pair
    public let keyId: String

    /// When this key pair was created
    public let createdAt: Date

    public init(privateKeyData: Data, publicKeyData: Data, keyId: String, createdAt: Date = Date()) {
        self.privateKeyData = privateKeyData
        self.publicKeyData = publicKeyData
        self.keyId = keyId
        self.createdAt = createdAt
    }
}

/// Public key data that can be shared with a partner device
public struct PublicKeyInfo: Codable, Sendable, Equatable {
    /// The raw public key bytes encoded as Base64
    public let publicKey: Data

    /// Unique identifier for this key
    public let keyId: String

    public init(publicKey: Data, keyId: String) {
        self.publicKey = publicKey
        self.keyId = keyId
    }

    // MARK: - Codable with Base64

    private enum CodingKeys: String, CodingKey {
        case publicKey
        case keyId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let base64String = try container.decode(String.self, forKey: .publicKey)
        guard let data = Data(base64Encoded: base64String) else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicKey,
                in: container,
                debugDescription: "Invalid Base64 string for public key"
            )
        }
        self.publicKey = data
        self.keyId = try container.decode(String.self, forKey: .keyId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publicKey.base64EncodedString(), forKey: .publicKey)
        try container.encode(keyId, forKey: .keyId)
    }
}
