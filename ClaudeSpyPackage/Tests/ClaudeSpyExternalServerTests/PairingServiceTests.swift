import Testing
@testable import ClaudeSpyExternalServer

@Suite("PairingService Tests")
struct PairingServiceTests {
    // Test public keys (32-byte base64 encoded)
    private let testMacPublicKey = "dGVzdC1tYWMtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="
    private let testMacKeyId = "mac-key-id-1"
    private let testIOSPublicKey = "dGVzdC1pb3MtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="
    private let testIOSKeyId = "ios-key-id-1"

    @Test("Registering a pairing code succeeds")
    func registerPairingCode() async throws {
        let service = PairingService()

        let result = await service.registerCode(
            code: "ABC123",
            deviceId: "mac-device-id",
            deviceName: "My Mac",
            username: "testuser",
            publicKey: testMacPublicKey,
            publicKeyId: testMacKeyId
        )

        #expect(result.success)
        #expect(result.pairId != nil)
        // pairId is now a UUID, not the code itself
    }

    @Test("Completing pairing with valid code succeeds")
    func completePairingWithValidCode() async throws {
        let service = PairingService()

        // First register the code
        let registerResult = await service.registerCode(
            code: "XYZ789",
            deviceId: "mac-device-id",
            deviceName: "My Mac",
            username: "testuser",
            publicKey: testMacPublicKey,
            publicKeyId: testMacKeyId
        )

        // Then complete pairing from iOS
        let result = await service.completePairing(
            code: "XYZ789",
            deviceId: "ios-device-id",
            deviceName: "My iPhone",
            publicKey: testIOSPublicKey,
            publicKeyId: testIOSKeyId
        )

        #expect(result.success)
        #expect(result.pairId != nil)
        #expect(result.partnerDeviceName == "My Mac")
        // Critical: both Mac and iOS should get the same pairId
        #expect(result.pairId == registerResult.pairId)
        // Verify partner's public key is returned
        #expect(result.partnerPublicKey == testMacPublicKey)
        #expect(result.partnerPublicKeyId == testMacKeyId)
        // Verify partner's username is returned
        #expect(result.partnerUsername == "testuser")
    }

    @Test("Completing pairing with invalid code fails")
    func completePairingWithInvalidCode() async throws {
        let service = PairingService()

        let result = await service.completePairing(
            code: "INVALID",
            deviceId: "ios-device-id",
            deviceName: "My iPhone",
            publicKey: testIOSPublicKey,
            publicKeyId: testIOSKeyId
        )

        #expect(!result.success)
        #expect(result.error != nil)
    }

    @Test("Duplicate pairing code registration fails")
    func duplicatePairingCodeFails() async throws {
        let service = PairingService()

        // Register first code
        let first = await service.registerCode(
            code: "SAME01",
            deviceId: "mac-1",
            deviceName: "Mac 1",
            username: "user1",
            publicKey: testMacPublicKey,
            publicKeyId: testMacKeyId
        )
        #expect(first.success)

        // Try to register same code again
        let second = await service.registerCode(
            code: "SAME01",
            deviceId: "mac-2",
            deviceName: "Mac 2",
            username: "user2",
            publicKey: "other-public-key",
            publicKeyId: "other-key-id"
        )
        #expect(!second.success)
    }
}
