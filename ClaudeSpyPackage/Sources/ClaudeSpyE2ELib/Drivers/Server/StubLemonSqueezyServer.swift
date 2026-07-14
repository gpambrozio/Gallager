import Foundation
import Logging
import Vapor

/// In-process stub of the Lemon Squeezy License API for E2E licensing
/// scenarios (issue #392).
///
/// Serves the three `POST /v1/licenses/*` endpoints the relay's
/// `LemonSqueezyAPIClient` calls, with LS-shaped JSON responses (snake_case,
/// same fields the relay's DTOs decode). The relay is pointed here via the
/// `LEMONSQUEEZY_API_BASE` env override applied by
/// `ServerDriver.start(port:licensedTrialDays:)`.
///
/// Exactly one license key (`acceptedLicenseKey`) activates successfully;
/// its activation response carries `meta.store_id` / `meta.product_id`
/// matching the ids the relay is configured with, so the wrong-product guard
/// passes. Any other key gets Lemon Squeezy's real failure shape: HTTP 404
/// with `{"activated": false, "error": "license_key not found."}` (the relay
/// client decodes the JSON body regardless of HTTP status).
public actor StubLemonSqueezyServer {
    /// Fixed local port — the relay port is 8765, this sits next to it.
    public static let port = 8_766
    /// Store/product ids baked into activation responses and into the
    /// `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID` env the licensed
    /// relay start applies — they must match for activation to succeed.
    public static let storeId = 123
    public static let productId = 456
    /// The one license key this stub accepts.
    public static let acceptedLicenseKey = "E2E-GALLAGER-LICENSE-392"
    /// Base URL the relay's `LEMONSQUEEZY_API_BASE` should point at.
    public static var baseURL: String { "http://127.0.0.1:\(port)" }

    private static let instanceId = "e2e-instance-392"

    private let logger = Logger(label: "e2e.stub-lemonsqueezy")
    private var app: Application?
    private var serverTask: Task<Void, Error>?

    public init() { }

    // MARK: - Lifecycle

    /// Start the stub server. Idempotent — a second call while running is a no-op.
    public func start() async throws {
        guard app == nil else { return }
        logger.info("Starting stub Lemon Squeezy server on port \(Self.port)")

        var env = Environment.testing
        env.arguments = ["vapor", "serve", "--port", "\(Self.port)", "--hostname", "127.0.0.1"]

        let app = try await Application.make(env)
        app.http.server.configuration.port = Self.port
        app.http.server.configuration.hostname = "127.0.0.1"
        Self.registerRoutes(app)

        self.app = app
        serverTask = Task {
            try await app.execute()
        }

        try await Polling.waitUntil(
            description: "stub Lemon Squeezy server healthy on port \(Self.port)",
            timeout: 10,
            pollInterval: 0.2
        ) {
            await self.isHealthy()
        }
        logger.info("Stub Lemon Squeezy server started on port \(Self.port)")
    }

    /// Stop the stub server. Safe to call when it never started.
    public func stop() async {
        guard app != nil else { return }
        logger.info("Stopping stub Lemon Squeezy server")
        serverTask?.cancel()
        serverTask = nil
        if let app {
            try? await app.asyncShutdown()
        }
        app = nil
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Routes

    private static func registerRoutes(_ app: Application) {
        app.get("health") { _ in "ok" }

        // LS sends form-encoded bodies; responses are JSON with an HTTP
        // status the real API would use (200 success, 404 unknown key).
        app.post("v1", "licenses", "activate") { req async throws -> Response in
            let request = try req.content.decode(LicenseRequest.self)
            guard request.licenseKey == acceptedLicenseKey else {
                return try jsonResponse(
                    FailureResponse(activated: false, valid: nil, error: "license_key not found."),
                    status: .notFound
                )
            }
            return try jsonResponse(
                LicenseResponse(
                    activated: true,
                    valid: nil,
                    licenseKey: .active,
                    instance: Instance(id: instanceId, name: request.instanceName ?? "Unknown"),
                    meta: Meta()
                ),
                status: .ok
            )
        }

        app.post("v1", "licenses", "validate") { req async throws -> Response in
            let request = try req.content.decode(LicenseRequest.self)
            guard request.licenseKey == acceptedLicenseKey else {
                return try jsonResponse(
                    FailureResponse(activated: nil, valid: false, error: "license_key not found."),
                    status: .notFound
                )
            }
            return try jsonResponse(
                LicenseResponse(
                    activated: nil,
                    valid: true,
                    licenseKey: .active,
                    instance: Instance(id: request.instanceId ?? instanceId, name: "Gallager"),
                    meta: Meta()
                ),
                status: .ok
            )
        }

        app.post("v1", "licenses", "deactivate") { req async throws -> Response in
            let request = try req.content.decode(LicenseRequest.self)
            guard request.licenseKey == acceptedLicenseKey else {
                return try jsonResponse(
                    DeactivateResponse(deactivated: false, error: "license_key not found."),
                    status: .notFound
                )
            }
            return try jsonResponse(
                DeactivateResponse(deactivated: true, error: nil),
                status: .ok
            )
        }
    }

    private static func jsonResponse(
        _ value: some Encodable, status: HTTPResponseStatus
    ) throws -> Response {
        let data = try JSONEncoder().encode(value)
        return Response(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    // MARK: - Wire models (snake_case per the LS License API docs)

    private struct LicenseRequest: Content {
        let licenseKey: String
        let instanceName: String?
        let instanceId: String?

        enum CodingKeys: String, CodingKey {
            case licenseKey = "license_key"
            case instanceName = "instance_name"
            case instanceId = "instance_id"
        }
    }

    private struct LicenseResponse: Encodable {
        let activated: Bool?
        let valid: Bool?
        let licenseKey: LicenseKey
        let instance: Instance
        let meta: Meta

        enum CodingKeys: String, CodingKey {
            case activated
            case valid
            case instance
            case meta
            case licenseKey = "license_key"
        }
    }

    private struct FailureResponse: Encodable {
        let activated: Bool?
        let valid: Bool?
        let error: String
    }

    private struct LicenseKey: Encodable {
        let status: String
        let activationLimit: Int
        let activationUsage: Int
        let expiresAt: String?

        static let active = LicenseKey(
            status: "active", activationLimit: 3, activationUsage: 1, expiresAt: nil
        )

        enum CodingKeys: String, CodingKey {
            case status
            case activationLimit = "activation_limit"
            case activationUsage = "activation_usage"
            case expiresAt = "expires_at"
        }
    }

    private struct Instance: Encodable {
        let id: String
        let name: String
    }

    private struct DeactivateResponse: Encodable {
        let deactivated: Bool
        let error: String?
    }

    private struct Meta: Encodable {
        let storeId = StubLemonSqueezyServer.storeId
        let productId = StubLemonSqueezyServer.productId

        enum CodingKeys: String, CodingKey {
            case storeId = "store_id"
            case productId = "product_id"
        }
    }
}
