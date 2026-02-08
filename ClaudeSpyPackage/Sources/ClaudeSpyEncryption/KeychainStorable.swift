import Foundation

/// Protocol abstracting Keychain-backed key storage.
///
/// Both the real ``KeyManager`` (Keychain-backed) and ``InMemoryKeyManager``
/// conform to this protocol, allowing E2E tests to inject in-memory storage
/// so they never touch the developer's real Keychain.
public protocol KeychainStorable: Actor {
    @discardableResult
    func generateKeyPair() throws -> StoredKeyPair
    func loadKeyPair() throws -> StoredKeyPair?
    nonisolated func loadKeyPairSync() throws -> StoredKeyPair?
    func deleteKeys() throws
    func hasStoredKeyPair() -> Bool
    func storeSessionKey(_ keyData: Data, for pairId: String) throws
    func loadSessionKey(for pairId: String) throws -> Data?
    func deleteSessionKey(for pairId: String) throws
    func hasStoredSessionKey(for pairId: String) -> Bool
}
