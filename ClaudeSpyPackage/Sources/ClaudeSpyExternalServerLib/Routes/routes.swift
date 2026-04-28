import Vapor

/// Registers all application routes
func routes(_ app: Application) throws {
    // Health check endpoint
    app.get("health") { _ -> HealthResponse in
        HealthResponse(status: "ok")
    }

    // Prometheus metrics endpoint at root (NOT under /api).
    // Authenticated via METRICS_TOKEN bearer header — see MetricsController.
    try app.register(collection: MetricsController())

    // API routes group
    let api = app.grouped("api")

    // Register controllers
    try api.register(collection: PairingController())
    try api.register(collection: WebSocketController())
}

// MARK: - Health Response

struct HealthResponse: Content {
    let status: String
}
