import Foundation
import Logging
import Vapor

/// Service that runs a local HTTP server to receive Claude Code hook events.
///
/// The server listens on localhost with a dynamically allocated port and accepts
/// POST requests at `/api/hooks` from the Claude Code plugin. Hook events are
/// parsed and forwarded via callback.
///
/// The actual port is written to `~/.claudespy-port` so hook scripts can discover it.
/// This enables multiple users to run ClaudeSpy simultaneously on the same machine.
public actor HookServerService {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.hookserver")

    /// The Vapor application instance
    private var app: Application?

    /// Whether the server is currently running
    public private(set) var isRunning = false

    /// The actual port the server is listening on (resolved after startup)
    public private(set) var serverPort: Int?

    /// Last error message if server failed to start
    public private(set) var lastError: String?

    /// Unified callback for all hook events
    private var onHookEvent: (@Sendable (HookEvent) async -> Void)?

    /// Path to the port file for hook script discovery
    private static var portFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claudespy-port"
    }

    // MARK: - Initialization

    public init() { }

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

            // Resolve the actual port from the bound socket
            let actualPort = app.http.server.shared.localAddress?.port
            serverPort = actualPort

            if let actualPort {
                writePortFile(port: actualPort)
            }

            isRunning = true
            lastError = nil

            logger.info("Hook server started on port \(actualPort.map(String.init) ?? "unknown")")
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
        serverPort = nil
        app = nil
        lastError = nil

        removePortFile()

        logger.info("Hook server stopped")
    }

    // MARK: - Application Setup

    private func createApplication() async throws -> Application {
        let app = try await Application.make(.testing)
        // Use port 0 to let the OS assign an available port
        app.http.server.configuration.port = 0
        app.http.server.configuration.hostname = "localhost"

        configureRoutes(app)

        return app
    }

    // MARK: - Port File Management

    /// Writes the actual listening port to a per-user file for hook script discovery.
    private func writePortFile(port: Int) {
        let path = Self.portFilePath
        do {
            try String(port).write(toFile: path, atomically: true, encoding: .utf8)
            logger.info("Wrote port file: \(path) with port \(port)")
        } catch {
            logger.error("Failed to write port file at \(path): \(error)")
        }
    }

    /// Removes the port file on shutdown.
    private func removePortFile() {
        let path = Self.portFilePath
        do {
            try FileManager.default.removeItem(atPath: path)
            logger.info("Removed port file: \(path)")
        } catch {
            // File may not exist, which is fine
            logger.debug("Port file removal skipped: \(error)")
        }
    }

    private func configureRoutes(_ app: Application) {
        // Health check endpoint
        app.get("health") { _ -> HTTPStatus in
            .ok
        }

        // Main hook endpoint - receives all hook types
        // Increase body size limit to 50MB to handle large tool payloads
        // (e.g., Write/Edit tools with large file content)
        app.on(.POST, "api", "hooks", body: .collect(maxSize: "50mb")) { [weak self] req async throws -> Response in
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

        let bodyData = Data(bodyString.utf8)

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
