import Crypto
import Foundation

/// Manages cryptographic key storage and retrieval.
///
/// On Apple platforms, keys are stored in the Keychain for security.
/// This actor ensures thread-safe access to key operations.
public actor KeyManager {
    // MARK: - Constants

    private let keychainService = "com.claudespy.e2ee"
    private let privateKeyAccount = "private-key"
    private let keyIdAccount = "key-id"

    // MARK: - Initialization

    public init() { }

    // MARK: - Key Generation

    /// Generates a new key pair and stores it in the Keychain.
    /// - Returns: The generated key pair
    /// - Throws: `CryptoError.keyGenerationFailed` if generation fails
    @discardableResult
    public func generateKeyPair() throws -> StoredKeyPair {
        // Generate a new Curve25519 key pair
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        // Create unique key ID
        let keyId = UUID().uuidString

        let storedPair = StoredKeyPair(
            privateKeyData: privateKey.rawRepresentation,
            publicKeyData: publicKey.rawRepresentation,
            keyId: keyId,
            createdAt: Date()
        )

        // Store in Keychain
        try storeInKeychain(storedPair)

        return storedPair
    }

    /// Loads an existing key pair from the Keychain.
    /// - Returns: The stored key pair, or nil if not found
    /// - Throws: `CryptoError.keychainError` on Keychain access failure
    public func loadKeyPair() throws -> StoredKeyPair? {
        // Query for private key data
        let privateKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var privateKeyResult: AnyObject?
        let privateKeyStatus = SecItemCopyMatching(privateKeyQuery as CFDictionary, &privateKeyResult)

        if privateKeyStatus == errSecItemNotFound {
            return nil
        }

        guard
            privateKeyStatus == errSecSuccess,
            let privateKeyData = privateKeyResult as? Data
        else {
            throw CryptoError.keychainError(status: privateKeyStatus)
        }

        // Query for key ID
        let keyIdQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyIdAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var keyIdResult: AnyObject?
        let keyIdStatus = SecItemCopyMatching(keyIdQuery as CFDictionary, &keyIdResult)

        guard
            keyIdStatus == errSecSuccess,
            let keyIdData = keyIdResult as? Data,
            let keyId = String(data: keyIdData, encoding: .utf8)
        else {
            throw CryptoError.keychainError(status: keyIdStatus)
        }

        // Reconstruct public key from private key
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let publicKey = privateKey.publicKey

            return StoredKeyPair(
                privateKeyData: privateKeyData,
                publicKeyData: publicKey.rawRepresentation,
                keyId: keyId,
                createdAt: Date() // We don't store creation date, use current
            )
        } catch {
            throw CryptoError.invalidPrivateKey
        }
    }

    /// Deletes all stored keys from the Keychain.
    /// Use this for factory reset or unpairing.
    public func deleteKeys() throws {
        // Delete private key
        let privateKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyAccount,
        ]

        let privateKeyStatus = SecItemDelete(privateKeyQuery as CFDictionary)
        if privateKeyStatus != errSecSuccess && privateKeyStatus != errSecItemNotFound {
            throw CryptoError.keychainError(status: privateKeyStatus)
        }

        // Delete key ID
        let keyIdQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyIdAccount,
        ]

        let keyIdStatus = SecItemDelete(keyIdQuery as CFDictionary)
        if keyIdStatus != errSecSuccess && keyIdStatus != errSecItemNotFound {
            throw CryptoError.keychainError(status: keyIdStatus)
        }
    }

    /// Checks if a key pair exists in the Keychain.
    public func hasStoredKeyPair() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyAccount,
            kSecReturnData as String: false,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Private Helpers

    private func storeInKeychain(_ keyPair: StoredKeyPair) throws {
        // First, delete any existing keys
        try? deleteKeys()

        // Store private key
        let privateKeyAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyAccount,
            kSecValueData as String: keyPair.privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let privateKeyStatus = SecItemAdd(privateKeyAttributes as CFDictionary, nil)
        guard privateKeyStatus == errSecSuccess else {
            throw CryptoError.keychainError(status: privateKeyStatus)
        }

        // Store key ID
        guard let keyIdData = keyPair.keyId.data(using: .utf8) else {
            throw CryptoError.keychainError(status: errSecParam)
        }

        let keyIdAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyIdAccount,
            kSecValueData as String: keyIdData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let keyIdStatus = SecItemAdd(keyIdAttributes as CFDictionary, nil)
        guard keyIdStatus == errSecSuccess else {
            // Clean up private key if key ID storage fails
            try? deleteKeys()
            throw CryptoError.keychainError(status: keyIdStatus)
        }
    }
}

// MARK: - In-Memory Key Manager for Testing

/// A key manager that stores keys in memory instead of Keychain.
/// Use this for testing or platforms without Keychain support.
public actor InMemoryKeyManager {
    private var storedKeyPair: StoredKeyPair?

    public init() { }

    @discardableResult
    public func generateKeyPair() throws -> StoredKeyPair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        let keyId = UUID().uuidString

        let keyPair = StoredKeyPair(
            privateKeyData: privateKey.rawRepresentation,
            publicKeyData: publicKey.rawRepresentation,
            keyId: keyId,
            createdAt: Date()
        )

        storedKeyPair = keyPair
        return keyPair
    }

    public func loadKeyPair() -> StoredKeyPair? {
        storedKeyPair
    }

    public func deleteKeys() {
        storedKeyPair = nil
    }

    public func hasStoredKeyPair() -> Bool {
        storedKeyPair != nil
    }
}
