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

        // MARK: - Generic Secret Operations

        /// Stores an arbitrary secret string under a keychain account (value, account).
        public var storeSecret: @Sendable (_ value: String, _ account: String) async throws -> Void

        /// Loads a secret by account; nil when absent.
        public var loadSecret: @Sendable (_ account: String) async throws -> String?

        /// Deletes a secret by account.
        public var deleteSecret: @Sendable (_ account: String) async throws -> Void
    }

    // MARK: - In-Memory Implementation

    public extension SecretsService {
        /// Creates a `SecretsService` backed by in-memory storage.
        ///
        /// Use this for E2E tests where the app must not write to the real Keychain.
        static func inMemory() -> SecretsService {
            let keyManager = InMemoryKeyManager()
            let keyPairStore = KeyPairStore()

            return SecretsService(
                generateKeyPair: {
                    let keyPair = try await keyManager.generateKeyPair()
                    keyPairStore.set(keyPair)
                    return keyPair
                },
                loadKeyPair: {
                    keyPairStore.get()
                },
                hasStoredKeyPair: {
                    await keyManager.hasStoredKeyPair()
                },
                deleteKeys: {
                    await keyManager.deleteKeys()
                    keyPairStore.set(nil)
                },
                storeSessionKey: { keyData, pairId in
                    await keyManager.storeSessionKey(keyData, for: pairId)
                },
                loadSessionKey: { pairId in
                    await keyManager.loadSessionKey(for: pairId)
                },
                deleteSessionKey: { pairId in
                    await keyManager.deleteSessionKey(for: pairId)
                },
                hasStoredSessionKey: { pairId in
                    await keyManager.hasStoredSessionKey(for: pairId)
                },
                storeSecret: { value, account in
                    await keyManager.storeSecret(value, account: account)
                },
                loadSecret: { account in
                    await keyManager.loadSecret(account: account)
                },
                deleteSecret: { account in
                    await keyManager.deleteSecret(account: account)
                }
            )
        }
    }

    /// Thread-safe wrapper for synchronous `loadKeyPair` access in `SecretsService.inMemory()`.
    final private class KeyPairStore: @unchecked Sendable {
        private let lock = NSLock()
        private var keyPair: StoredKeyPair?

        func get() -> StoredKeyPair? {
            lock.withLock { keyPair }
        }

        func set(_ value: StoredKeyPair?) {
            lock.withLock { keyPair = value }
        }
    }

    // MARK: - DependencyKey

    extension SecretsService: DependencyKey {
        public static var previewValue: SecretsService {
            .inMemory()
        }

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
                },
                storeSecret: { value, account in
                    try await keyManager.storeSecret(value, account: account)
                },
                loadSecret: { account in
                    try await keyManager.loadSecret(account: account)
                },
                deleteSecret: { account in
                    try await keyManager.deleteSecret(account: account)
                }
            )
        }
    }
#endif
