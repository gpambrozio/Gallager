import Crypto
import Foundation

#if canImport(Security)
    import Security

    // MARK: - Dynamic Keychain Access Group Discovery

    /// Thread-safe cache for the discovered access group with atomic get-or-compute.
    final private class AccessGroupCache: @unchecked Sendable {
        private var cachedValue: String?
        private let lock = NSLock()

        /// Atomically get cached value or compute and cache a new one.
        /// This prevents race conditions where multiple threads could perform
        /// the expensive keychain discovery operation simultaneously.
        func getOrCompute(_ compute: () -> String?) -> String? {
            lock.withLock {
                if let cached = cachedValue {
                    return cached
                }
                let value = compute()
                cachedValue = value
                return value
            }
        }
    }

    /// Cache for the discovered access group to avoid repeated keychain queries.
    private let accessGroupCache = AccessGroupCache()

    /// Returns the shared keychain access group for ClaudeSpy app and extensions.
    ///
    /// This dynamically discovers the access group at runtime by storing a temporary
    /// keychain item and reading back its access group attribute. The keychain automatically
    /// assigns the app's default access group (first entry in keychain-access-groups entitlement)
    /// which includes the team ID prefix.
    ///
    /// - Returns: The full access group (e.g., "XG2WG7U93U.br.eng.gustavo.claudespy.shared"),
    ///   or nil if discovery fails
    public func getSharedKeychainAccessGroup() -> String? {
        accessGroupCache.getOrCompute {
            discoverKeychainAccessGroup()
        }
    }

    /// Performs the actual keychain access group discovery.
    private func discoverKeychainAccessGroup() -> String? {
        let tempAccount = "br.eng.gustavo.claudespy.accessgroup.discovery"
        let tempService = "br.eng.gustavo.claudespy.accessgroup"

        // Query attributes including accessibility to check if migration is needed
        let queryExisting: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tempService,
            kSecAttrAccount as String: tempAccount,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        var status = SecItemCopyMatching(queryExisting as CFDictionary, &result)

        // Check if existing item needs migration (wrong accessibility level)
        if
            status == errSecSuccess,
            let attributes = result as? [String: Any],
            let existingAccessibility = attributes[kSecAttrAccessible as String] as? String,
            existingAccessibility != (kSecAttrAccessibleAfterFirstUnlock as String) {
            // Delete item with wrong accessibility so we can re-add with correct level
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: tempService,
                kSecAttrAccount as String: tempAccount,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            status = errSecItemNotFound
            result = nil
        }

        // If not found (or deleted for migration), store with correct accessibility
        if status == errSecItemNotFound {
            // Use AfterFirstUnlock so Notification Service Extension can access
            // when device is locked (but has been unlocked at least once since boot)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: tempService,
                kSecAttrAccount as String: tempAccount,
                kSecValueData as String: Data("accessgroup-probe".utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]

            status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                return nil
            }

            // Now query it back to get attributes
            status = SecItemCopyMatching(queryExisting as CFDictionary, &result)
        }

        guard
            status == errSecSuccess,
            let attributes = result as? [String: Any],
            let accessGroup = attributes[kSecAttrAccessGroup as String] as? String
        else {
            return nil
        }

        return accessGroup
    }

    /// Shared keychain access group for ClaudeSpy app and extensions.
    ///
    /// This is a convenience property that returns the discovered access group.
    /// The access group is discovered at runtime by querying the keychain.
    ///
    /// - Warning: Will crash if access group discovery fails. Use `getSharedKeychainAccessGroup()`
    ///   for graceful handling.
    public var sharedKeychainAccessGroup: String {
        guard let accessGroup = getSharedKeychainAccessGroup() else {
            fatalError(
                "Failed to discover keychain access group. " +
                    "Ensure the app has keychain-access-groups entitlement configured."
            )
        }
        return accessGroup
    }

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
        private let sessionKeyAccountPrefix = "session-key-"

        /// Returns the account name for a session key with a specific pairId
        private nonisolated func sessionKeyAccount(for pairId: String) -> String {
            "\(sessionKeyAccountPrefix)\(pairId)"
        }

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
        /// Marked nonisolated since Keychain APIs are thread-safe.
        private nonisolated func baseKeychainAttributes(account: String) -> [String: Any] {
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

            // Note: Per-pairId session keys should be deleted via deleteSessionKey(for:)
            // when individual Macs are unpaired
        }

        /// Checks if a key pair exists in the Keychain.
        public func hasStoredKeyPair() -> Bool {
            var query = baseKeychainAttributes(account: privateKeyAccount)
            query[kSecReturnData as String] = false

            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecSuccess
        }

        /// Loads an existing key pair from the Keychain.
        ///
        /// This is `nonisolated` since Keychain APIs are thread-safe, allowing
        /// synchronous access from any context.
        /// - Returns: The stored key pair, or nil if not found
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public nonisolated func loadKeyPair() throws -> StoredKeyPair? {
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
                    createdAt: Date()
                )
            } catch {
                throw CryptoError.invalidPrivateKey
            }
        }

        // MARK: - Session Key Storage (Per-PairId)

        /// Stores the derived symmetric session key for a specific host (identified by pairId).
        ///
        /// Call this after establishing an E2EE session so that the Notification Service
        /// Extension can decrypt push notification payloads from this host.
        ///
        /// - Parameters:
        ///   - keyData: The raw symmetric key data (32 bytes for ChaCha20)
        ///   - pairId: The pair ID identifying which host this session key belongs to
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func storeSessionKey(_ keyData: Data, for pairId: String) throws {
            let account = sessionKeyAccount(for: pairId)
            let query = baseKeychainAttributes(account: account)

            // Try to update existing item first (upsert pattern)
            let updateAttrs: [String: Any] = [
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]

            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

            if updateStatus == errSecItemNotFound {
                // No existing item — add new one
                let attributes = storeAttributes(account: account, data: keyData)
                let addStatus = SecItemAdd(attributes as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw CryptoError.keychainError(status: addStatus)
                }
            } else if updateStatus != errSecSuccess {
                throw CryptoError.keychainError(status: updateStatus)
            }
        }

        /// Loads the stored session key for a specific host from Keychain.
        ///
        /// Used by the Notification Service Extension to decrypt push notifications.
        ///
        /// - Parameter pairId: The pair ID identifying which host's session key to load
        /// - Returns: The session key data, or nil if not found
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func loadSessionKey(for pairId: String) throws -> Data? {
            let account = sessionKeyAccount(for: pairId)

            var query = baseKeychainAttributes(account: account)
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

        /// Deletes the session key for a specific host from Keychain.
        ///
        /// - Parameter pairId: The pair ID identifying which host's session key to delete
        public func deleteSessionKey(for pairId: String) throws {
            let account = sessionKeyAccount(for: pairId)
            let query = baseKeychainAttributes(account: account)
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw CryptoError.keychainError(status: status)
            }
        }

        /// Checks if a session key exists for a specific host.
        ///
        /// - Parameter pairId: The pair ID to check
        public func hasStoredSessionKey(for pairId: String) -> Bool {
            let account = sessionKeyAccount(for: pairId)
            var query = baseKeychainAttributes(account: account)
            query[kSecReturnData as String] = false

            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecSuccess
        }

        // MARK: - Generic Secrets

        /// Stores an arbitrary secret string under `account` (upsert).
        ///
        /// - Parameters:
        ///   - value: The secret string to store.
        ///   - account: The keychain account to store the secret under.
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func storeSecret(_ value: String, account: String) throws {
            let data = Data(value.utf8)
            let query = baseKeychainAttributes(account: account)

            // Try to update existing item first (upsert pattern)
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]

            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

            if updateStatus == errSecItemNotFound {
                // No existing item — add new one
                let attributes = storeAttributes(account: account, data: data)
                let addStatus = SecItemAdd(attributes as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw CryptoError.keychainError(status: addStatus)
                }
            } else if updateStatus != errSecSuccess {
                throw CryptoError.keychainError(status: updateStatus)
            }
        }

        /// Loads a secret stored via `storeSecret`.
        ///
        /// - Parameter account: The keychain account to load the secret from.
        /// - Returns: The secret string, or nil if not found
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func loadSecret(account: String) throws -> String? {
            var query = baseKeychainAttributes(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecItemNotFound {
                return nil
            }

            guard status == errSecSuccess, let data = result as? Data else {
                throw CryptoError.keychainError(status: status)
            }

            return String(bytes: data, encoding: .utf8)
        }

        /// Deletes a secret stored via `storeSecret` (missing item is not an error).
        ///
        /// - Parameter account: The keychain account to delete the secret from.
        /// - Throws: `CryptoError.keychainError` on Keychain access failure
        public func deleteSecret(account: String) throws {
            let query = baseKeychainAttributes(account: account)
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw CryptoError.keychainError(status: status)
            }
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
            let keyIdData = Data(keyPair.keyId.utf8)

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
///
/// - Warning: **TESTING ONLY** - This manager provides NO SECURITY.
///   Keys are lost when the process terminates and are not protected from memory dumps.
///   Never use this in production code.
@_spi(Testing)
public actor InMemoryKeyManager {
    private var storedKeyPair: StoredKeyPair?
    private var storedSessionKeys: [String: Data] = [:]
    private var storedSecrets: [String: String] = [:]

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
        storedSessionKeys.removeAll()
    }

    public func hasStoredKeyPair() -> Bool {
        storedKeyPair != nil
    }

    // MARK: - Session Key Storage (Per-PairId)

    public func storeSessionKey(_ keyData: Data, for pairId: String) {
        storedSessionKeys[pairId] = keyData
    }

    public func loadSessionKey(for pairId: String) -> Data? {
        storedSessionKeys[pairId]
    }

    public func deleteSessionKey(for pairId: String) {
        storedSessionKeys.removeValue(forKey: pairId)
    }

    public func hasStoredSessionKey(for pairId: String) -> Bool {
        storedSessionKeys[pairId] != nil
    }

    public func deleteAllSessionKeys() {
        storedSessionKeys.removeAll()
    }

    // MARK: - Generic Secrets

    public func storeSecret(_ value: String, account: String) {
        storedSecrets[account] = value
    }

    public func loadSecret(account: String) -> String? {
        storedSecrets[account]
    }

    public func deleteSecret(account: String) {
        storedSecrets.removeValue(forKey: account)
    }
}
