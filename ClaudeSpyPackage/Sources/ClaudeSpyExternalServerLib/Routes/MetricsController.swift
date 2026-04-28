import Vapor

/// Build version baked into the binary at compile time.
/// For now, a static string; replace later with git SHA injected via -D flag.
private let buildVersion = "dev"

/// Exposes Prometheus-format metrics at `GET /metrics`.
///
/// Requires `Authorization: Bearer <METRICS_TOKEN>`. If `METRICS_TOKEN` is empty
/// (unset at startup), every request is rejected with 401.
struct MetricsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("metrics", use: handle)
    }

    @Sendable
    private func handle(req: Request) async throws -> Response {
        let expected = req.application.metricsToken
        guard
            !expected.isEmpty,
            let header = req.headers.bearerAuthorization?.token,
            header == expected else {
            throw Abort(.unauthorized)
        }

        let metrics = req.application.metricsService
        let pairs = await req.application.pairingService.activePairCount
        let counts = await req.application.connectionHub.connectionCounts()
        let start = req.application.storage[ProcessStartTimeKey.self] ?? Date()
        let uptime = Int(Date().timeIntervalSince(start))

        let snapshot = MetricsSnapshot(
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
}
