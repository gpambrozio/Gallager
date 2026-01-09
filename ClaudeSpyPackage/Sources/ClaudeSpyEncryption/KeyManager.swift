import Crypto
import Foundation

#if canImport(Security)
    import Security

    /// Manages cryptographic key storage and retrieval.
    ///
    /// On Apple platforms, keys are stored in the Keychain for security.
    /// This actor ensures thread-safe access to key operations.
    ///
    /// ## Keychain Sharing
    /// To share keys with app extensions (e.g., Notification Service Extension),
    /// initialize with an `accessGroup`:
    /// ```swift
    /// let keyManager = KeyManager(accessGroup: "group.com.yourapp.shared")
    /// ```
    /// Both the main app and extension must have matching entitlements.
    public actor KeyManager {
        // MARK: - Constants

        private let keychainService = "com.claudespy.e2ee"
        private let privateKeyAccount = "private-key"
        private let keyIdAccount = "key-id"
        private let sessionKeyAccount = "session-key"

        /// Optional keychain access group for sharing with app extensions.
        /// When set, keys are stored in the shared keychain accessible by the app group.
        private let accessGroup: String?

        // MARK: - Initialization

        /// Creates a new KeyManager.
        /// - Parameter accessGroup: Optional keychain access group for sharing keys with extensions.
        ///   If nil, keys are only accessible to the main app.
        public init(accessGroup: String? = nil) {
            self.accessGroup = accessGroup
        }

        // MARK: - Private Helpers

        /// Builds base keychain query attributes, including access group if configured.
        private func baseKeychainAttributes(account: String) -> [String: Any] {
            var attrs: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
            ]
            if let accessGroup {
                attrs[kSecAttrAccessGroup as String] = accessGroup
            }
            return attrs
        }

        /// Builds keychain store attributes with accessibility settings.
        private func storeAttributes(account: String, data: Data) -> [String: Any] {
            var attrs = baseKeychainAttributes(account: account)
            attrs[kSecValueData as String] = data
            // Use AfterFirstUnlock so extensions can access keys when device is locked
            // (but has been unlocked at least once since boot)
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return attrs
        }

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
            var privateKeyQuery = baseKeychainAttributes(account: privateKeyAccount)
            privateKeyQuery[kSecReturnData as String] = true
            privateKeyQuery[kSecMatchLimit as String] = kSecMatchLimitOne

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
            var keyIdQuery = baseKeychainAttributes(account: keyIdAccount)
            keyIdQuery[kSecReturnData as String] = true
            keyIdQuery[kSecMatchLimit as String] = kSecMatchLimitOne

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

        /// Deletes all stored keys from the Keychain, including session keys.
        /// Use this for factory reset or unpairing.
        public func deleteKeys() throws {
            // Delete private key
            let privateKeyQuery = baseKeychainAttributes(account: privateKeyAccount)
            let privateKeyStatus = SecItemDelete(privateKeyQuery as CFDictionary)
            if privateKeyStatus != errSecSuccess && privateKeyStatus != errSecItemNotFound {
                throw CryptoError.keychainError(status: privateKeyStatus)
            }

            // Delete key ID
            let keyIdQuery = baseKeychainAttributes(account: keyIdAccount)
            let keyIdStatus = SecItemDelete(keyIdQuery as CFDictionary)
            if keyIdStatus != errSecSuccess && keyIdStatus != errSecItemNotFound {
                throw CryptoError.keychainError(status: keyIdStatus)
            }

            // Delete session key
            let sessionKeyQuery = baseKeychainAttributes(account: sessionKeyAccount)
            let sessionKeyStatus = SecItemDelete(sessionKeyQuery as CFDictionary)
            if sessionKeyStatus != errSecSuccess && sessionKeyStatus != errSecItemNotFound {
                throw CryptoError.keychainError(status: sessionKeyStatus)
            }
        }

        /// Checks if a key pair exists in the Keychain.
        public func hasStoredKeyPair() -> Bool {
            var query = baseKeychainAttributes(account: privateKeyAccount)
            query[kSecReturnData as String] = false

            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecSuccess
        }

        // MARK: - Session Key Storage

        /// Stores the derived symmetric session key for use by app extensions.
        ///
        /// Call this after establishing an E2EE session so that the Notification Service
        /// Extension can decrypt push notification payloads.
        ///
        /// - Parameter keyData: The raw symmetric key data (32 bytes for ChaCha20)
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func storeSessionKey(_ keyData: Data) throws {
            // Delete existing session key first
            let deleteQuery = baseKeychainAttributes(account: sessionKeyAccount)
            SecItemDelete(deleteQuery as CFDictionary)

            // Store new session key
            let attributes = storeAttributes(account: sessionKeyAccount, data: keyData)
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw CryptoError.keychainError(status: status)
            }
        }

        /// Loads the stored session key from Keychain.
        ///
        /// Used by the Notification Service Extension to decrypt push notifications.
        ///
        /// - Returns: The session key data, or nil if not found
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func loadSessionKey() throws -> Data? {
            var query = baseKeychainAttributes(account: sessionKeyAccount)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecItemNotFound {
                return nil
            }

            guard status == errSecSuccess, let keyData = result as? Data else {
                throw CryptoError.keychainError(status: status)
            }

            return keyData
        }

        /// Deletes only the session key from Keychain.
        ///
        /// Call this when disconnecting or when re-pairing to clear the old session.
        public func deleteSessionKey() throws {
            let query = baseKeychainAttributes(account: sessionKeyAccount)
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw CryptoError.keychainError(status: status)
            }
        }

        /// Checks if a session key exists in the Keychain.
        public func hasStoredSessionKey() -> Bool {
            var query = baseKeychainAttributes(account: sessionKeyAccount)
            query[kSecReturnData as String] = false

            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecSuccess
        }

        // MARK: - Private Key Storage

        private func storeInKeychain(_ keyPair: StoredKeyPair) throws {
            // First, delete any existing keys
            try? deleteKeys()

            // Store private key
            let privateKeyAttributes = storeAttributes(account: privateKeyAccount, data: keyPair.privateKeyData)
            let privateKeyStatus = SecItemAdd(privateKeyAttributes as CFDictionary, nil)
            guard privateKeyStatus == errSecSuccess else {
                throw CryptoError.keychainError(status: privateKeyStatus)
            }

            // Store key ID
            guard let keyIdData = keyPair.keyId.data(using: .utf8) else {
                throw CryptoError.keychainError(status: errSecParam)
            }

            let keyIdAttributes = storeAttributes(account: keyIdAccount, data: keyIdData)
            let keyIdStatus = SecItemAdd(keyIdAttributes as CFDictionary, nil)
            guard keyIdStatus == errSecSuccess else {
                // Clean up private key if key ID storage fails
                try? deleteKeys()
                throw CryptoError.keychainError(status: keyIdStatus)
            }
        }
    }
#endif

// MARK: - In-Memory Key Manager for Testing

/// A key manager that stores keys in memory instead of Keychain.
/// Use this for testing or platforms without Keychain support.
public actor InMemoryKeyManager {
    private var storedKeyPair: StoredKeyPair?
    private var storedSessionKey: Data?

    public init(accessGroup _: String? = nil) { }

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
        storedSessionKey = nil
    }

    public func hasStoredKeyPair() -> Bool {
        storedKeyPair != nil
    }

    // MARK: - Session Key Storage

    public func storeSessionKey(_ keyData: Data) {
        storedSessionKey = keyData
    }

    public func loadSessionKey() -> Data? {
        storedSessionKey
    }

    public func deleteSessionKey() {
        storedSessionKey = nil
    }

    public func hasStoredSessionKey() -> Bool {
        storedSessionKey != nil
    }
}
