import Testing
@testable import ClaudeSpyExternalServer

@Suite("PairingService Tests")
struct PairingServiceTests {
    @Test("Registering a pairing code succeeds")
    func registerPairingCode() async throws {
        let service = PairingService()

        let result = await service.registerCode(
            code: "ABC123",
            deviceId: "mac-device-id",
            deviceName: "My Mac"
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
            deviceName: "My Mac"
        )

        // Then complete pairing from iOS
        let result = await service.completePairing(
            code: "XYZ789",
            deviceId: "ios-device-id",
            deviceName: "My iPhone"
        )

        #expect(result.success)
        #expect(result.pairId != nil)
        #expect(result.partnerDeviceName == "My Mac")
        // Critical: both Mac and iOS should get the same pairId
        #expect(result.pairId == registerResult.pairId)
    }

    @Test("Completing pairing with invalid code fails")
    func completePairingWithInvalidCode() async throws {
        let service = PairingService()

        let result = await service.completePairing(
            code: "INVALID",
            deviceId: "ios-device-id",
            deviceName: "My iPhone"
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
            deviceName: "Mac 1"
        )
        #expect(first.success)

        // Try to register same code again
        let second = await service.registerCode(
            code: "SAME01",
            deviceId: "mac-2",
            deviceName: "Mac 2"
        )
        #expect(!second.success)
    }
}
