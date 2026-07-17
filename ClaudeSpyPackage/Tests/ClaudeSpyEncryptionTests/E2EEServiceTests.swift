@_spi(Testing) import ClaudeSpyEncryption
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@Suite("E2EE Service Tests")
struct E2EEServiceTests {
    // MARK: - Key Generation Tests

    @Test("Service generates valid key pair on init")
    func serviceGeneratesKeyPair() async throws {
        let service = try await createService()

        // Public key should be 32 bytes (Curve25519)
        #expect(service.publicKey.count == 32)
        #expect(!service.keyId.isEmpty)
    }

    @Test("Service reuses existing key pair")
    func serviceReusesKeyPair() async throws {
        let keyManager = InMemoryKeyManager()
        let keyPairStore = KeyPairStore()

        // First service generates a key
        let service1 = try await createService(keyManager: keyManager, keyPairStore: keyPairStore)
        let publicKey1 = service1.publicKey
        let keyId1 = service1.keyId

        // Second service should reuse the same key (shared KeyPairStore)
        let service2 = try await createService(keyManager: keyManager, keyPairStore: keyPairStore)
        let publicKey2 = service2.publicKey
        let keyId2 = service2.keyId

        #expect(publicKey1 == publicKey2)
        #expect(keyId1 == keyId2)
    }

    // MARK: - Session Establishment Tests

    @Test("Two services can establish a session")
    func sessionEstablishment() async throws {
        let (service1, service2) = try await createPairedServices()

        // Both should now have sessions established
        let isEstablished1 = await service1.isSessionEstablished
        let isEstablished2 = await service2.isSessionEstablished

        #expect(isEstablished1)
        #expect(isEstablished2)
    }

    @Test("Session establishment fails with invalid public key")
    func invalidPublicKeyFails() async throws {
        let service = try await createService()

        await #expect(throws: CryptoError.self) {
            try await service.establishSession(
                partnerPublicKey: Data(repeating: 0xFF, count: 10), // Invalid length
                partnerKeyId: "invalid",
                pairId: "test"
            )
        }
    }

    // MARK: - Encryption/Decryption Tests

    @Test("Encrypt and decrypt round trip")
    func encryptDecryptRoundTrip() async throws {
        let (service1, service2) = try await createPairedServices()

        let plaintext = Data("Hello, encrypted world!".utf8)

        // Service 1 encrypts
        let encrypted = try await service1.encrypt(plaintext)

        // Service 2 decrypts
        let decrypted = try await service2.decrypt(encrypted)

        #expect(decrypted == plaintext)
    }

    @Test("Encrypt and decrypt Codable types")
    func encryptDecryptCodable() async throws {
        let (service1, service2) = try await createPairedServices()

        let message = TestMessage(id: UUID(), content: "Secret message", timestamp: Date())

        // Encrypt
        let encrypted = try await service1.encrypt(message)

        // Decrypt
        let decrypted: TestMessage = try await service2.decrypt(encrypted, as: TestMessage.self)

        #expect(decrypted.id == message.id)
        #expect(decrypted.content == message.content)
    }

    @Test("Bidirectional encryption works")
    func bidirectionalEncryption() async throws {
        let (service1, service2) = try await createPairedServices()

        // Service 1 -> Service 2
        let message1 = Data("From service 1".utf8)
        let encrypted1 = try await service1.encrypt(message1)
        let decrypted1 = try await service2.decrypt(encrypted1)
        #expect(decrypted1 == message1)

        // Service 2 -> Service 1
        let message2 = Data("From service 2".utf8)
        let encrypted2 = try await service2.encrypt(message2)
        let decrypted2 = try await service1.decrypt(encrypted2)
        #expect(decrypted2 == message2)
    }

    @Test("Encryption without session fails")
    func encryptWithoutSessionFails() async throws {
        let service = try await createService()

        await #expect(throws: CryptoError.self) {
            _ = try await service.encrypt(Data("test".utf8))
        }
    }

    @Test("Decryption without session fails")
    func decryptWithoutSessionFails() async throws {
        let service = try await createService()

        let payload = EncryptedPayload(
            ciphertext: Data(repeating: 0, count: 32),
            senderKeyId: "test"
        )

        await #expect(throws: CryptoError.self) {
            _ = try await service.decrypt(payload)
        }
    }

    @Test("Third party cannot decrypt messages")
    func thirdPartyCannotDecrypt() async throws {
        let (service1, service2) = try await createPairedServices()
        let service3 = try await createService()

        // Service 3 "intercepts" the conversation by establishing with service 1
        try await service3.establishSession(
            partnerPublicKey: service1.publicKey,
            partnerKeyId: service1.keyId,
            pairId: "test-pair"
        )

        // Service 1 sends to service 2
        let message = Data("Secret message".utf8)
        let encrypted = try await service1.encrypt(message)

        // Service 2 can decrypt
        let decrypted = try await service2.decrypt(encrypted)
        #expect(decrypted == message)

        // Service 3 cannot decrypt (different shared secret)
        await #expect(throws: CryptoError.self) {
            _ = try await service3.decrypt(encrypted)
        }
    }

    @Test("Tampering with ciphertext is detected")
    func tamperingDetected() async throws {
        let (service1, service2) = try await createPairedServices()

        let message = Data("Original message".utf8)
        let encrypted = try await service1.encrypt(message)

        // Tamper with the ciphertext
        var tamperedCiphertext = encrypted.ciphertext
        if tamperedCiphertext.count > 20 {
            tamperedCiphertext[20] ^= 0xFF // Flip bits
        }

        let tamperedPayload = EncryptedPayload(
            ciphertext: tamperedCiphertext,
            senderKeyId: encrypted.senderKeyId
        )

        // Decryption should fail due to authentication
        await #expect(throws: CryptoError.self) {
            _ = try await service2.decrypt(tamperedPayload)
        }
    }

    @Test("Version mismatch is rejected")
    func versionMismatch() async throws {
        let (service1, service2) = try await createPairedServices()

        let message = Data("Test".utf8)
        let encrypted = try await service1.encrypt(message)

        // Create payload with wrong version
        let wrongVersionPayload = EncryptedPayload(
            ciphertext: encrypted.ciphertext,
            senderKeyId: encrypted.senderKeyId,
            version: 999
        )

        await #expect(throws: CryptoError.self) {
            _ = try await service2.decrypt(wrongVersionPayload)
        }
    }

    // MARK: - Session Clear Tests

    @Test("Clear session prevents encryption")
    func clearSessionPreventsEncryption() async throws {
        let (service1, _) = try await createPairedServices()

        // Clear the session
        await service1.clearSession()

        // Should not be established anymore
        let isEstablished = await service1.isSessionEstablished
        #expect(!isEstablished)

        // Should fail to encrypt
        await #expect(throws: CryptoError.self) {
            _ = try await service1.encrypt(Data("test".utf8))
        }
    }

    // MARK: - Payload Encoding Tests

    @Test("EncryptedPayload encodes to JSON correctly")
    func payloadJsonEncoding() throws {
        let ciphertext = Data([0x01, 0x02, 0x03, 0x04])
        let payload = EncryptedPayload(ciphertext: ciphertext, senderKeyId: "test-key", version: 1)

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(payload)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Should contain base64 encoded ciphertext
        #expect(jsonString.contains("AQIDBA==")) // Base64 of 0x01020304
        #expect(jsonString.contains("test-key"))
    }

    @Test("EncryptedPayload decodes from JSON correctly")
    func payloadJsonDecoding() throws {
        let json = """
        {"ciphertext":"AQIDBA==","senderKeyId":"test-key","version":1}
        """

        let decoder = JSONDecoder()
        let payload = try decoder.decode(EncryptedPayload.self, from: Data(json.utf8))

        #expect(payload.ciphertext == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(payload.senderKeyId == "test-key")
        #expect(payload.version == 1)
    }

    // MARK: - Helpers

    private func createService(
        keyManager: InMemoryKeyManager = InMemoryKeyManager(),
        keyPairStore: KeyPairStore = KeyPairStore()
    ) async throws -> E2EEService {
        try await withDependencies {
            $0[SecretsService.self] = makeSecretsService(keyManager: keyManager, keyPairStore: keyPairStore)
        } operation: {
            try await E2EEService()
        }
    }

    private func createPairedServices() async throws -> (E2EEService, E2EEService) {
        let keyManager1 = InMemoryKeyManager()
        let keyManager2 = InMemoryKeyManager()

        let service1 = try await withDependencies {
            $0[SecretsService.self] = makeSecretsService(keyManager: keyManager1)
        } operation: {
            try await E2EEService()
        }

        let service2 = try await withDependencies {
            $0[SecretsService.self] = makeSecretsService(keyManager: keyManager2)
        } operation: {
            try await E2EEService()
        }

        let pairId = "test-pair"

        // Exchange public keys and establish sessions
        try await service1.establishSession(
            partnerPublicKey: service2.publicKey,
            partnerKeyId: service2.keyId,
            pairId: pairId
        )

        try await service2.establishSession(
            partnerPublicKey: service1.publicKey,
            partnerKeyId: service1.keyId,
            pairId: pairId
        )

        return (service1, service2)
    }
}

// MARK: - Test Helpers

private struct TestMessage: Codable, Equatable {
    let id: UUID
    let content: String
    let timestamp: Date
}

// MARK: - SecretsService Test Support

/// Thread-safe wrapper around a stored key pair for synchronous test access.
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

/// Creates a `SecretsService` backed by an `InMemoryKeyManager` for testing.
private func makeSecretsService(
    keyManager: InMemoryKeyManager,
    keyPairStore: KeyPairStore = KeyPairStore()
) -> SecretsService {
    SecretsService(
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
