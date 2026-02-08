import ClaudeSpyExternalServerLib
import Foundation
import Logging
import Vapor

/// Runs the Vapor relay server in-process for E2E testing
public actor ServerDriver {
    private let logger = Logger(label: "e2e.server-driver")
    private var app: Application?
    private var serverTask: Task<Void, Error>?
    private var port = 8_765

    public init() { }

    // MARK: - Server Lifecycle

    /// Start the server on the given port
    public func start(port: Int = 8_765) async throws {
        self.port = port
        logger.info("Starting test server on port \(port)")

        var env = Environment.testing
        env.arguments = ["serve", "--port", "\(port)", "--hostname", "127.0.0.1"]

        let app = try await Application.make(env)

        // Override port before configure
        app.http.server.configuration.port = port
        app.http.server.configuration.hostname = "127.0.0.1"

        try await configure(app)

        self.app = app

        // Run the server in a background task
        serverTask = Task {
            try await app.execute()
        }

        // Wait for it to be ready
        try await waitForHealthy(timeout: 10)

        logger.info("Test server started on port \(port)")
    }

    /// Stop the server
    public func stop() async throws {
        logger.info("Stopping test server")

        serverTask?.cancel()
        serverTask = nil

        if let app {
            try await app.asyncShutdown()
        }
        app = nil
    }

    /// Wait for the server to be healthy
    public func waitForHealthy(timeout: TimeInterval = 10) async throws {
        try await Polling.waitUntil(
            description: "server healthy on port \(port)",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            await self.isHealthy()
        }
    }

    /// Check server health
    public func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                return false
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            return json?["status"] == "ok"
        } catch {
            return false
        }
    }

    // MARK: - State Inspection

    /// Get the number of active pairings
    public func getActivePairingCount() async -> Int {
        guard let app else { return 0 }
        return await app.activePairingCount
    }

    /// Reset all server state
    public func resetState() async {
        guard let app else { return }
        await app.resetPairingState()
        logger.info("Server state reset")
    }
}
