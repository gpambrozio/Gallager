import Crypto
import Foundation

/// Salt used for HKDF key derivation. This is a protocol constant.
private let protocolSalt = Data("ClaudeSpy-E2EE-v1".utf8)

/// End-to-end encryption service for secure communication between paired devices.
///
/// This service handles:
/// - Key pair generation and storage via KeyManager
/// - Session establishment with partner's public key
/// - Message encryption and decryption using ChaChaPoly
///
/// ## Usage
/// ```swift
/// let service = try await E2EEService()
///
/// // Share publicKeyInfo with partner during pairing
/// let myPublicKey = service.publicKeyInfo
///
/// // After receiving partner's public key, establish session
/// try service.establishSession(
///     partnerPublicKey: partnerKeyData,
///     partnerKeyId: partnerKeyId,
///     pairId: "pair-uuid"
/// )
///
/// // Encrypt outgoing messages
/// let encrypted = try service.encrypt(messageData)
///
/// // Decrypt incoming messages
/// let decrypted = try service.decrypt(encryptedPayload)
/// ```
final public class E2EEService: Sendable {
    // MARK: - Properties

    /// Our key pair loaded from storage
    private let keyPair: StoredKeyPair

    /// The derived symmetric key for this session (nonisolated access requires lock)
    private let sessionState: SessionState

    /// Actor to manage mutable session state
    private actor SessionState {
        var symmetricKey: SymmetricKey?
        var partnerPublicKey: Curve25519.KeyAgreement.PublicKey?
        var partnerKeyId: String?
        var pairId: String?

        func establish(
            symmetricKey: SymmetricKey,
            partnerPublicKey: Curve25519.KeyAgreement.PublicKey,
            partnerKeyId: String,
            pairId: String
        ) {
            self.symmetricKey = symmetricKey
            self.partnerPublicKey = partnerPublicKey
            self.partnerKeyId = partnerKeyId
            self.pairId = pairId
        }

        func clear() {
            symmetricKey = nil
            partnerPublicKey = nil
            partnerKeyId = nil
            pairId = nil
        }

        func getSymmetricKey() -> SymmetricKey? {
            symmetricKey
        }

        func isEstablished() -> Bool {
            symmetricKey != nil
        }

        func getPairId() -> String? {
            pairId
        }
    }

    // MARK: - Initialization

    /// Creates a new E2EE service, loading or generating keys as needed.
    ///
    /// - Parameter keyManager: The key manager to use for key storage.
    ///   Defaults to a new KeyManager instance.
    /// - Throws: `CryptoError` if key loading/generation fails
    public init(keyManager: KeyManager = KeyManager()) async throws {
        // Try to load existing key pair, or generate new one
        if let existingPair = try await keyManager.loadKeyPair() {
            self.keyPair = existingPair
        } else {
            self.keyPair = try await keyManager.generateKeyPair()
        }

        self.sessionState = SessionState()
    }

    /// Creates a service with a pre-existing key pair.
    /// Useful for testing or when keys are managed externally.
    public init(keyPair: StoredKeyPair) {
        self.keyPair = keyPair
        self.sessionState = SessionState()
    }

    // MARK: - Public Key Access

    /// Our public key data that can be shared with partners.
    public var publicKey: Data {
        keyPair.publicKeyData
    }

    /// Our key ID for identifying which key was used.
    public var keyId: String {
        keyPair.keyId
    }

    /// Complete public key info for sharing during pairing.
    public var publicKeyInfo: PublicKeyInfo {
        PublicKeyInfo(publicKey: keyPair.publicKeyData, keyId: keyPair.keyId)
    }

    // MARK: - Session Management

    /// Establishes an encryption session with a partner device.
    ///
    /// This derives a shared symmetric key using ECDH key agreement
    /// and HKDF key derivation. Both devices will derive the same key
    /// when they each call this method with the other's public key.
    ///
    /// - Parameters:
    ///   - partnerPublicKey: The partner's raw public key data (32 bytes)
    ///   - partnerKeyId: The partner's key identifier
    ///   - pairId: The pairing identifier (used in key derivation for domain separation)
    /// - Throws: `CryptoError.invalidPublicKey` if the public key is invalid
    /// - Throws: `CryptoError.keyAgreementFailed` if ECDH fails
    public func establishSession(
        partnerPublicKey: Data,
        partnerKeyId: String,
        pairId: String
    ) async throws {
        // Parse partner's public key
        let partnerKey: Curve25519.KeyAgreement.PublicKey
        do {
            partnerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: partnerPublicKey)
        } catch {
            throw CryptoError.invalidPublicKey
        }

        // Reconstruct our private key
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyPair.privateKeyData)
        } catch {
            throw CryptoError.invalidPrivateKey
        }

        // Perform ECDH key agreement
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: partnerKey)
        } catch {
            throw CryptoError.keyAgreementFailed(underlying: error)
        }

        // Derive symmetric key using HKDF
        // Include pairId in sharedInfo for domain separation
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: protocolSalt,
            sharedInfo: pairId.data(using: .utf8) ?? Data(),
            outputByteCount: 32
        )

        await sessionState.establish(
            symmetricKey: symmetricKey,
            partnerPublicKey: partnerKey,
            partnerKeyId: partnerKeyId,
            pairId: pairId
        )
    }

    /// Clears the current session, removing the derived key.
    /// Call this when disconnecting or unpairing.
    public func clearSession() async {
        await sessionState.clear()
    }

    /// Whether a session is currently established.
    public var isSessionEstablished: Bool {
        get async {
            await sessionState.isEstablished()
        }
    }

    // MARK: - Encryption

    /// Encrypts data for transmission to the paired device.
    ///
    /// Uses ChaChaPoly authenticated encryption with a randomly generated nonce.
    /// The nonce is prepended to the ciphertext in the returned payload.
    ///
    /// - Parameter data: The plaintext data to encrypt
    /// - Returns: An encrypted payload ready for transmission
    /// - Throws: `CryptoError.sessionNotEstablished` if no session exists
    /// - Throws: `CryptoError.encryptionFailed` if encryption fails
    public func encrypt(_ data: Data) async throws -> EncryptedPayload {
        guard let symmetricKey = await sessionState.getSymmetricKey() else {
            throw CryptoError.sessionNotEstablished
        }

        do {
            let sealedBox = try ChaChaPoly.seal(data, using: symmetricKey)
            return EncryptedPayload(
                ciphertext: sealedBox.combined,
                senderKeyId: keyPair.keyId
            )
        } catch {
            throw CryptoError.encryptionFailed(underlying: error)
        }
    }

    /// Encrypts a Codable value for transmission.
    ///
    /// - Parameter value: The value to encode and encrypt
    /// - Returns: An encrypted payload ready for transmission
    /// - Throws: Encoding errors or encryption errors
    public func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedPayload {
        let data = try JSONEncoder().encode(value)
        return try await encrypt(data)
    }

    // MARK: - Decryption

    /// Decrypts an encrypted payload received from the paired device.
    ///
    /// Verifies the authentication tag to ensure the message wasn't tampered with.
    ///
    /// - Parameter payload: The encrypted payload to decrypt
    /// - Returns: The decrypted plaintext data
    /// - Throws: `CryptoError.sessionNotEstablished` if no session exists
    /// - Throws: `CryptoError.unsupportedVersion` if protocol version doesn't match
    /// - Throws: `CryptoError.decryptionFailed` if decryption or authentication fails
    public func decrypt(_ payload: EncryptedPayload) async throws -> Data {
        // Check protocol version
        guard payload.version == encryptionProtocolVersion else {
            throw CryptoError.unsupportedVersion(
                received: payload.version,
                supported: encryptionProtocolVersion
            )
        }

        guard let symmetricKey = await sessionState.getSymmetricKey() else {
            throw CryptoError.sessionNotEstablished
        }

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: payload.ciphertext)
            return try ChaChaPoly.open(sealedBox, using: symmetricKey)
        } catch {
            throw CryptoError.decryptionFailed(underlying: error)
        }
    }

    /// Decrypts an encrypted payload and decodes it as a Codable type.
    ///
    /// - Parameters:
    ///   - payload: The encrypted payload to decrypt
    ///   - type: The type to decode the decrypted data as
    /// - Returns: The decoded value
    /// - Throws: Decryption errors or decoding errors
    public func decrypt<T: Decodable>(_ payload: EncryptedPayload, as type: T.Type) async throws -> T {
        let data = try await decrypt(payload)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Convenience Extensions

public extension E2EEService {
    /// Establishes a session using a PublicKeyInfo structure.
    func establishSession(partnerKeyInfo: PublicKeyInfo, pairId: String) async throws {
        try await establishSession(
            partnerPublicKey: partnerKeyInfo.publicKey,
            partnerKeyId: partnerKeyInfo.keyId,
            pairId: pairId
        )
    }
}

// MARK: - SwiftUI Environment Support

#if canImport(SwiftUI)
    import SwiftUI

    /// Environment key for E2EEService
    private struct E2EEServiceKey: EnvironmentKey {
        static let defaultValue: E2EEService? = nil
    }

    public extension EnvironmentValues {
        /// The E2EE service for encryption operations
        var e2eeService: E2EEService? {
            get { self[E2EEServiceKey.self] }
            set { self[E2EEServiceKey.self] = newValue }
        }
    }

    public extension View {
        /// Sets the E2EE service for this view hierarchy
        func e2eeService(_ service: E2EEService) -> some View {
            environment(\.e2eeService, service)
        }
    }
#endif
