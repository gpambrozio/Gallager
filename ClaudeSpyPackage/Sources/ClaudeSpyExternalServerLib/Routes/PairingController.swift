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

    /// Host registers a pairing code
    /// POST /api/pairing/register
    @Sendable
    func registerPairingCode(req: Request) async throws -> PairingResponse {
        let registration = try req.content.decode(PairingRegistration.self)

        // Hosted-relay gate: hosts need a trial or active license. First touch
        // auto-starts the trial, so a fresh host sails through.
        let entitlement = await req.application.licensingService
            .checkEntitlement(hostDeviceId: registration.deviceId)
        guard entitlement.isAllowed else {
            await req.application.metricsService.incrementBlockedHostAttempts()
            return .error(ErrorInfo(
                message: "An active subscription is required to use the hosted relay",
                code: ErrorMessage.subscriptionRequiredCode
            ))
        }

        return await req.application.pairingService.registerCode(
            code: registration.pairingCode,
            deviceId: registration.deviceId,
            deviceName: registration.deviceName,
            username: registration.username,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
    }

    /// Viewer completes pairing with a code
    /// POST /api/pairing/complete
    @Sendable
    func completePairing(req: Request) async throws -> PairingResponse {
        let completion = try req.content.decode(PairingCompletion.self)

        return await req.application.pairingService.completePairing(
            code: completion.pairingCode,
            deviceId: completion.deviceId,
            deviceName: completion.deviceName,
            publicKey: completion.publicKey,
            publicKeyId: completion.publicKeyId
        )
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
        let hostConnected = await connectionHub.isHostConnected(pairId: pairId)
        let viewerConnected = await connectionHub.isViewerConnected(pairId: pairId)
        let viewerDeviceName = await pairingService.getViewerDeviceName(pairId: pairId)

        return PairingStatus(
            valid: isValid,
            hostConnected: hostConnected,
            viewerConnected: viewerConnected,
            viewerDeviceName: viewerDeviceName
        )
    }

    /// Delete a pairing
    /// DELETE /api/pairing/:pairId
    @Sendable
    func deletePairing(req: Request) async throws -> HTTPStatus {
        guard let pairId = req.parameters.get("pairId") else {
            throw Abort(.badRequest, reason: "Missing pairId parameter")
        }

        // Notify both sides that the pairing has been removed before disconnecting
        await req.application.connectionHub.broadcast(.unpaired, to: pairId)

        await req.application.pairingService.removePair(pairId: pairId)
        await req.application.connectionHub.disconnectAll(pairId: pairId)

        return .noContent
    }
}
