import Foundation
import Logging
import Vapor

/// Service that runs a local HTTP server to receive Claude Code hook events.
///
/// The server listens on localhost:6111 and accepts POST requests at `/api/hooks`
/// from the Claude Code plugin. Hook events are parsed and forwarded via callback.
public actor HookServerService {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.hookserver")

    /// The Vapor application instance
    private var app: Application?

    /// Whether the server is currently running
    public private(set) var isRunning = false

    /// The port the server listens on (matches hook.py)
    public nonisolated let serverPort = 6111

    /// Last error message if server failed to start
    public private(set) var lastError: String?

    /// Unified callback for all hook events
    private var onHookEvent: (@Sendable (HookEvent) async -> Void)?

    // MARK: - Initialization

    public init() {}

    // MARK: - Configuration

    /// Sets the event handler callback for hook events
    /// - Parameter handler: Callback invoked when a hook event is received
    public func setEventHandler(_ handler: @escaping @Sendable (HookEvent) async -> Void) {
        onHookEvent = handler
    }

    // MARK: - Server Lifecycle

    /// Start the HTTP server
    public func startServer() async {
        guard !isRunning else {
            logger.warning("Hook server is already running")
            return
        }

        do {
            let app = try await createApplication()
            self.app = app

            try await app.startup()

            isRunning = true
            lastError = nil

            logger.info("Hook server started on port \(serverPort)")
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            logger.error("Failed to start hook server: \(error)")
        }
    }

    /// Stop the HTTP server
    public func stopServer() async {
        guard isRunning else {
            logger.warning("Hook server is not running")
            return
        }

        isRunning = false
        app = nil
        lastError = nil

        logger.info("Hook server stopped")
    }

    // MARK: - Application Setup

    private func createApplication() async throws -> Application {
        let app = try await Application.make(.testing)
        app.http.server.configuration.port = serverPort
        app.http.server.configuration.hostname = "localhost"

        configureRoutes(app)

        return app
    }

    private func configureRoutes(_ app: Application) {
        // Health check endpoint
        app.get("health") { _ -> HTTPStatus in
            .ok
        }

        // Main hook endpoint - receives all hook types
        app.post("api", "hooks") { [weak self] req async throws -> Response in
            guard let self else {
                throw Abort(.internalServerError)
            }

            return try await self.handleHookRequest(req)
        }
    }

    // MARK: - Request Handling

    private func handleHookRequest(_ req: Request) async throws -> Response {
        // Parse query parameters
        let queryParams = try? req.query.decode(HookQueryParams.self)
        let projectPath = queryParams?.projectPath
        let tmuxPane = queryParams?.tmuxPane

        // Read request body
        guard let bodyBuffer = req.body.data else {
            logger.error("Hook request with empty body")
            throw Abort(.badRequest, reason: "Empty request body")
        }

        let bodyString = String(buffer: bodyBuffer)
        logger.info("Hook request received", metadata: [
            "projectPath": "\(projectPath ?? "nil")",
            "tmuxPane": "\(tmuxPane ?? "nil")",
            "bodyLength": "\(bodyString.count)",
        ])

        guard let bodyData = bodyString.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Invalid body encoding")
        }

        // Parse the hook action
        let hookAction: HookAction
        do {
            hookAction = try HookAction.from(jsonData: bodyData)
        } catch {
            logger.error("Failed to parse hook body: \(error)")
            // Still accept the request but log the error
            return emptyResponse()
        }

        // Create the event and notify caller
        let event = HookEvent(
            action: hookAction,
            projectPath: projectPath,
            tmuxPane: tmuxPane
        )

        if let onHookEvent {
            await onHookEvent(event)
        }

        logger.info("Hook event processed", metadata: [
            "eventName": "\(hookAction.eventName)",
            "sessionId": "\(hookAction.sessionId)",
        ])

        return emptyResponse()
    }

    private func emptyResponse() -> Response {
        Response(status: .ok, body: .init(string: ""))
    }
}
