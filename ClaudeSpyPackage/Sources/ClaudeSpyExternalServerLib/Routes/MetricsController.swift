import Vapor

/// Build version baked into the binary at compile time.
/// For now, a static string; replace later with git SHA injected via -D flag.
private let buildVersion = "dev"

/// Exposes Prometheus-format metrics at `GET /metrics`.
///
/// Requires `Authorization: Bearer <METRICS_TOKEN>`. If `METRICS_TOKEN` is unset,
/// every request is rejected with 401.
struct MetricsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("metrics", use: handle)
    }

    @Sendable
    private func handle(req: Request) async throws -> Response {
        guard
            let expected = req.application.metricsToken,
            let header = req.headers.bearerAuthorization?.token,
            Self.constantTimeEquals(header, expected) else {
            throw Abort(.unauthorized)
        }

        let metrics = req.application.metricsService

        // Run independent actor reads concurrently — Prometheus scrapes every 15s
        // and these touch different actors with no ordering requirement.
        async let pairs = req.application.pairingService.activePairCount
        async let counts = req.application.connectionHub.connectionCounts()

        guard let start = req.application.storage[ProcessStartTimeKey.self] else {
            fatalError("ProcessStartTimeKey not configured. Call configure(_:) first.")
        }
        // ContinuousClock is monotonic, so uptime is immune to wall-clock jumps
        // (NTP step, manual clock change).
        let uptime = Int((ContinuousClock.now - start).components.seconds)

        let snapshot = await MetricsSnapshot(
            activePairs: pairs,
            hostsConnected: counts.host,
            viewersConnected: counts.viewer,
            uptimeSeconds: uptime
        )

        let body = await metrics.render(snapshot: snapshot, buildVersion: buildVersion)

        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(
            type: "text",
            subType: "plain",
            parameters: ["version": "0.0.4"]
        )
        return Response(status: .ok, headers: headers, body: .init(string: body))
    }

    /// Compare two strings byte-wise without short-circuiting, to avoid
    /// leaking the secret length / prefix via timing side channels.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aUTF8 = a.utf8
        let bUTF8 = b.utf8
        guard aUTF8.count == bUTF8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(aUTF8, bUTF8) {
            diff |= x ^ y
        }
        return diff == 0
    }
}
