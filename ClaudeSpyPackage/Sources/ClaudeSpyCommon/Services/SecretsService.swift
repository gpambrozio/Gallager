#if canImport(Security)
    import ClaudeSpyEncryption
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// A dependency for managing cryptographic keys and secrets via Keychain.
    ///
    /// This wraps `KeyManager` operations so they can be controlled in tests and previews.
    /// Use `@Dependency(SecretsService.self)` to access it.
    @DependencyClient
    public struct SecretsService: Sendable {
        // MARK: - Key Pair Operations

        /// Generates a new key pair and stores it in the Keychain.
        public var generateKeyPair: @Sendable () async throws -> StoredKeyPair

        /// Loads an existing key pair from the Keychain.
        public var loadKeyPair: @Sendable () async throws -> StoredKeyPair?

        /// Synchronously loads an existing key pair from the Keychain.
        public var loadKeyPairSync: @Sendable () throws -> StoredKeyPair?

        /// Checks if a key pair exists in the Keychain.
        public var hasStoredKeyPair: @Sendable () async -> Bool = { false }

        /// Deletes all stored keys from the Keychain.
        public var deleteKeys: @Sendable () async throws -> Void

        // MARK: - Session Key Operations

        /// Stores a session key for a specific pair ID.
        public var storeSessionKey: @Sendable (_ keyData: Data, _ pairId: String) async throws -> Void

        /// Loads a session key for a specific pair ID.
        public var loadSessionKey: @Sendable (_ pairId: String) async throws -> Data?

        /// Deletes a session key for a specific pair ID.
        public var deleteSessionKey: @Sendable (_ pairId: String) async throws -> Void

        /// Checks if a session key exists for a specific pair ID.
        public var hasStoredSessionKey: @Sendable (_ pairId: String) async -> Bool = { _ in false }

        // MARK: - Key Manager Access

        /// Returns the underlying KeyManager for use with E2EEService.
        /// This allows services that need a KeyManager instance to get one
        /// without directly constructing it.
        public var keyManager: @Sendable () -> KeyManager = { KeyManager() }
    }

    // MARK: - DependencyKey

    extension SecretsService: DependencyKey {
        public static var liveValue: SecretsService {
            let keyManager = KeyManager()

            return SecretsService(
                generateKeyPair: {
                    try await keyManager.generateKeyPair()
                },
                loadKeyPair: {
                    try await keyManager.loadKeyPair()
                },
                loadKeyPairSync: {
                    try keyManager.loadKeyPairSync()
                },
                hasStoredKeyPair: {
                    await keyManager.hasStoredKeyPair()
                },
                deleteKeys: {
                    try await keyManager.deleteKeys()
                },
                storeSessionKey: { keyData, pairId in
                    try await keyManager.storeSessionKey(keyData, for: pairId)
                },
                loadSessionKey: { pairId in
                    try await keyManager.loadSessionKey(for: pairId)
                },
                deleteSessionKey: { pairId in
                    try await keyManager.deleteSessionKey(for: pairId)
                },
                hasStoredSessionKey: { pairId in
                    await keyManager.hasStoredSessionKey(for: pairId)
                },
                keyManager: {
                    keyManager
                }
            )
        }
    }

    // MARK: - Shared Keychain Access Group

    extension SecretsService {
        /// Creates a SecretsService configured with a shared keychain access group.
        ///
        /// Use this for iOS apps that need to share keys with app extensions
        /// (e.g., Notification Service Extension).
        ///
        /// - Parameter accessGroup: The keychain access group identifier
        /// - Returns: A configured SecretsService
        public static func shared(accessGroup: String) -> SecretsService {
            let keyManager = KeyManager(accessGroup: accessGroup)

            return SecretsService(
                generateKeyPair: {
                    try await keyManager.generateKeyPair()
                },
                loadKeyPair: {
                    try await keyManager.loadKeyPair()
                },
                loadKeyPairSync: {
                    try keyManager.loadKeyPairSync()
                },
                hasStoredKeyPair: {
                    await keyManager.hasStoredKeyPair()
                },
                deleteKeys: {
                    try await keyManager.deleteKeys()
                },
                storeSessionKey: { keyData, pairId in
                    try await keyManager.storeSessionKey(keyData, for: pairId)
                },
                loadSessionKey: { pairId in
                    try await keyManager.loadSessionKey(for: pairId)
                },
                deleteSessionKey: { pairId in
                    try await keyManager.deleteSessionKey(for: pairId)
                },
                hasStoredSessionKey: { pairId in
                    await keyManager.hasStoredSessionKey(for: pairId)
                },
                keyManager: {
                    keyManager
                }
            )
        }
    }
#endif
