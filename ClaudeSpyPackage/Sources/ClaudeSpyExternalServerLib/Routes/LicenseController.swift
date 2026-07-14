import ClaudeSpyNetworking
import Vapor

/// HTTP endpoints for host license management. These return billing state
/// only — never session data — and are keyed by deviceId, the same trust
/// model as pairing registration.
struct LicenseController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let license = routes.grouped("license")

        license.post("activate", use: activate)
        license.delete("activation", use: deactivate)
        license.get("status", use: status)
    }

    /// POST /api/license/activate
    @Sendable
    func activate(req: Request) async throws -> LicenseStatus {
        let request = try req.content.decode(LicenseActivationRequest.self)
        do {
            return try await req.application.licensingService.activate(
                licenseKey: request.licenseKey,
                deviceId: request.deviceId,
                deviceName: request.deviceName
            )
        } catch let error as LicensingError {
            throw Abort(.badRequest, reason: error.userMessage)
        }
    }

    /// DELETE /api/license/activation?deviceId=x
    @Sendable
    func deactivate(req: Request) async throws -> HTTPStatus {
        guard let deviceId = req.query[String.self, at: "deviceId"] else {
            throw Abort(.badRequest, reason: "Missing deviceId parameter")
        }
        await req.application.licensingService.deactivate(deviceId: deviceId)
        return .noContent
    }

    /// GET /api/license/status?deviceId=x — read-only, never starts a trial.
    @Sendable
    func status(req: Request) async throws -> LicenseStatus {
        guard let deviceId = req.query[String.self, at: "deviceId"] else {
            throw Abort(.badRequest, reason: "Missing deviceId parameter")
        }
        return await req.application.licensingService.status(deviceId: deviceId)
    }
}
