import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyExternalServerLib

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

        guard case let .registered(info) = result else {
            Issue.record("Expected .registered, got \(result)")
            return
        }
        #expect(!info.pairId.isEmpty)
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

        guard case let .registered(registerInfo) = registerResult else {
            Issue.record("Expected .registered, got \(registerResult)")
            return
        }

        // Then complete pairing from iOS
        let result = await service.completePairing(
            code: "XYZ789",
            deviceId: "ios-device-id",
            deviceName: "My iPhone",
            publicKey: testIOSPublicKey,
            publicKeyId: testIOSKeyId
        )

        guard case let .paired(pairedInfo) = result else {
            Issue.record("Expected .paired, got \(result)")
            return
        }

        #expect(pairedInfo.partnerDeviceName == "My Mac")
        // Critical: both Mac and iOS should get the same pairId
        #expect(pairedInfo.pairId == registerInfo.pairId)
        // Verify partner's public key is returned
        #expect(pairedInfo.partnerPublicKey == testMacPublicKey)
        #expect(pairedInfo.partnerPublicKeyId == testMacKeyId)
        // Verify partner's username is returned
        #expect(pairedInfo.partnerUsername == "testuser")
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

        guard case let .error(errorInfo) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(!errorInfo.message.isEmpty)
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

        guard case .registered = first else {
            Issue.record("Expected .registered, got \(first)")
            return
        }

        // Try to register same code again
        let second = await service.registerCode(
            code: "SAME01",
            deviceId: "mac-2",
            deviceName: "Mac 2",
            username: "user2",
            publicKey: "other-public-key",
            publicKeyId: "other-key-id"
        )

        guard case .error = second else {
            Issue.record("Expected .error, got \(second)")
            return
        }
    }
}
