import Foundation

/// Errors that can occur during encryption operations
public enum CryptoError: Error, Sendable, LocalizedError {
    /// Failed to generate a key pair
    case keyGenerationFailed(underlying: Error?)

    /// Failed to derive shared secret from key agreement
    case keyAgreementFailed(underlying: Error?)

    /// Session not established - call establishSession first
    case sessionNotEstablished

    /// Failed to encrypt data
    case encryptionFailed(underlying: Error?)

    /// Failed to decrypt data - ciphertext may be corrupted or wrong key
    case decryptionFailed(underlying: Error?)

    /// Invalid public key data format
    case invalidPublicKey

    /// Invalid private key data format
    case invalidPrivateKey

    /// Invalid or empty pair ID for key derivation
    case invalidPairId

    #if canImport(Security)
        /// Keychain operation failed (Apple platforms only)
        case keychainError(status: OSStatus)
    #endif

    /// Key not found in Keychain
    case keyNotFound

    /// Protocol version mismatch
    case unsupportedVersion(received: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(underlying):
            return "Failed to generate key pair: \(underlying?.localizedDescription ?? "unknown error")"
        case let .keyAgreementFailed(underlying):
            return "Failed to derive shared secret: \(underlying?.localizedDescription ?? "unknown error")"
        case .sessionNotEstablished:
            return "Encryption session not established. Call establishSession() first."
        case let .encryptionFailed(underlying):
            return "Failed to encrypt data: \(underlying?.localizedDescription ?? "unknown error")"
        case let .decryptionFailed(underlying):
            return "Failed to decrypt data: \(underlying?.localizedDescription ?? "authentication failed or corrupted data")"
        case .invalidPublicKey:
            return "Invalid public key data format"
        case .invalidPrivateKey:
            return "Invalid private key data format"
        case .invalidPairId:
            return "Invalid or empty pair ID for key derivation"
        #if canImport(Security)
            case let .keychainError(status):
                return "Keychain operation failed with status: \(status)"
        #endif
        case .keyNotFound:
            return "Encryption key not found in Keychain"
        case let .unsupportedVersion(received, supported):
            return "Unsupported encryption protocol version \(received). Supported: \(supported)"
        }
    }
}
