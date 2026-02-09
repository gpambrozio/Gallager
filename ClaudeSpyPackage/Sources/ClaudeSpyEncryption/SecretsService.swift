#if canImport(Security)
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
        public var loadKeyPair: @Sendable () throws -> StoredKeyPair?

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
    }

    // MARK: - DependencyKey

    extension SecretsService: DependencyKey {
        public static var liveValue: SecretsService {
            #if os(iOS)
                let keyManager = KeyManager(accessGroup: sharedKeychainAccessGroup)
            #else
                let keyManager = KeyManager()
            #endif

            return build(from: keyManager)
        }

        private static func build(from keyManager: KeyManager) -> SecretsService {
            SecretsService(
                generateKeyPair: {
                    try await keyManager.generateKeyPair()
                },
                loadKeyPair: {
                    try keyManager.loadKeyPair()
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
                }
            )
        }
    }
#endif
