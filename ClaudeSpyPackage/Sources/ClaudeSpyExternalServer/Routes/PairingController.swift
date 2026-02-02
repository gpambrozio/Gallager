import ClaudeSpyNetworking
import Vapor

/// Handles HTTP endpoints for device pairing
struct PairingController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let pairing = routes.grouped("pairing")

        pairing.post("register", use: registerPairingCode)
        pairing.post("complete", use: completePairing)
        pairing.get(":pairId", "status", use: getPairingStatus)
        pairing.delete(":pairId", use: deletePairing)
    }

    /// Mac registers a pairing code
    /// POST /api/pairing/register
    @Sendable
    func registerPairingCode(req: Request) async throws -> PairingResponse {
        let registration = try req.content.decode(PairingRegistration.self)

        let result = await req.application.pairingService.registerCode(
            code: registration.pairingCode,
            deviceId: registration.deviceId,
            deviceName: registration.deviceName,
            username: registration.username,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )

        return result
    }

    /// iOS completes pairing with a code
    /// POST /api/pairing/complete
    @Sendable
    func completePairing(req: Request) async throws -> PairingResponse {
        let completion = try req.content.decode(PairingCompletion.self)

        let result = await req.application.pairingService.completePairing(
            code: completion.pairingCode,
            deviceId: completion.deviceId,
            deviceName: completion.deviceName,
            publicKey: completion.publicKey,
            publicKeyId: completion.publicKeyId
        )

        return result
    }

    /// Get pairing status
    /// GET /api/pairing/:pairId/status
    @Sendable
    func getPairingStatus(req: Request) async throws -> PairingStatus {
        guard let pairId = req.parameters.get("pairId") else {
            throw Abort(.badRequest, reason: "Missing pairId parameter")
        }

        let connectionHub = req.application.connectionHub
        let pairingService = req.application.pairingService

        let isValid = await pairingService.isValidPair(pairId: pairId)
        let macConnected = await connectionHub.isMacConnected(pairId: pairId)
        let iosConnected = await connectionHub.isIOSConnected(pairId: pairId)

        return PairingStatus(
            valid: isValid,
            macConnected: macConnected,
            iosConnected: iosConnected
        )
    }

    /// Delete a pairing
    /// DELETE /api/pairing/:pairId
    @Sendable
    func deletePairing(req: Request) async throws -> HTTPStatus {
        guard let pairId = req.parameters.get("pairId") else {
            throw Abort(.badRequest, reason: "Missing pairId parameter")
        }

        await req.application.pairingService.removePair(pairId: pairId)
        await req.application.connectionHub.disconnectAll(pairId: pairId)

        return .noContent
    }
}
