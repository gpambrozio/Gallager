import Dependencies
import DependenciesMacros
import Foundation
import Logging
import Vapor

/// A dependency for receiving Claude Code hook events via a local HTTP server.
///
/// Wraps Vapor HTTP server so it can be controlled in tests.
/// Use `@Dependency(HookServerService.self)` to access it.
@DependencyClient
public struct HookServerService: Sendable {
    /// Sets the event handler callback for hook events.
    public var setEventHandler: @Sendable (_ handler: @escaping @Sendable (HookEvent) async -> Void) async -> Void

    /// Start the HTTP server.
    public var startServer: @Sendable () async -> Void

    /// Stop the HTTP server.
    public var stopServer: @Sendable () async -> Void
}

// MARK: - DependencyKey

extension HookServerService: DependencyKey {
    /// Default port file path (`~/.claudespy-port`).
    public static let defaultPortFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claudespy-port"
    }()

    /// Create a live `HookServerService` that writes its port to the given file path.
    public static func live(portFilePath: String) -> HookServerService {
        let server = LiveHookServer(portFilePath: portFilePath)

        return HookServerService(
            setEventHandler: { handler in
                await server.setEventHandler(handler)
            },
            startServer: {
                await server.startServer()
            },
            stopServer: {
                await server.stopServer()
            }
        )
    }

    public static var liveValue: HookServerService {
        .live(portFilePath: defaultPortFilePath)
    }
}

// MARK: - Live Implementation

/// Actor that runs a local HTTP server to receive Claude Code hook events.
private actor LiveHookServer {
    private let logger = Logger(label: "com.claudespy.hookserver")
    private var app: Application?
    private var isRunning = false
    private var serverPort: Int?
    private var lastError: String?
    private var onHookEvent: (@Sendable (HookEvent) async -> Void)?

    private static let basePort = 6_111
    private static let maxPortAttempts = 10

    private let portFilePath: String

    init(portFilePath: String) {
        self.portFilePath = portFilePath
    }

    func setEventHandler(_ handler: @escaping @Sendable (HookEvent) async -> Void) {
        onHookEvent = handler
    }

    func startServer() async {
        guard !isRunning else {
            logger.warning("Hook server is already running")
            return
        }

        for portOffset in 0..<Self.maxPortAttempts {
            let port = Self.basePort + portOffset
            do {
                let app = try await createApplication(port: port)
                self.app = app

                try app.server.start()

                guard let actualPort = app.http.server.shared.localAddress?.port else {
                    lastError = "Server started but could not resolve listening port"
                    isRunning = false
                    try? await app.asyncShutdown()
                    self.app = nil
                    return
                }

                serverPort = actualPort
                writePortFile(port: actualPort)

                isRunning = true
                lastError = nil

                logger.info("Hook server started on port \(actualPort)")
                return
            } catch {
                try? await app?.asyncShutdown()
                app = nil

                let errorMessage = error.localizedDescription
                if portOffset < Self.maxPortAttempts - 1 {
                    logger.info("Port \(port) unavailable, trying next port: \(errorMessage)")
                } else {
                    lastError = "All ports \(Self.basePort)–\(Self.basePort + Self.maxPortAttempts - 1) unavailable: \(errorMessage)"
                    isRunning = false
                    logger.error("Failed to start hook server: \(lastError ?? "")")
                }
            }
        }
    }

    func stopServer() async {
        guard isRunning else {
            logger.warning("Hook server is not running")
            return
        }

        isRunning = false
        serverPort = nil
        try? await app?.asyncShutdown()
        app = nil
        lastError = nil

        removePortFile()

        logger.info("Hook server stopped")
    }

    // MARK: - Application Setup

    private func createApplication(port: Int) async throws -> Application {
        let app = try await Application.make(.testing)
        app.http.server.configuration.port = port
        app.http.server.configuration.hostname = "localhost"

        configureRoutes(app)

        return app
    }

    // MARK: - Port File Management

    private func writePortFile(port: Int) {
        let path = portFilePath
        do {
            try String(port).write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
            logger.info("Wrote port file: \(path) with port \(port)")
        } catch {
            logger.error("Failed to write port file at \(path): \(error)")
        }
    }

    private func removePortFile() {
        let path = portFilePath
        do {
            try FileManager.default.removeItem(atPath: path)
            logger.info("Removed port file: \(path)")
        } catch {
            logger.debug("Port file removal skipped: \(error)")
        }
    }

    private func configureRoutes(_ app: Application) {
        app.get("health") { _ -> HTTPStatus in
            .ok
        }

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
        let queryParams = try? req.query.decode(HookQueryParams.self)
        let projectPath = queryParams?.projectPath
        let tmuxPane = queryParams?.tmuxPane

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

        let hookAction: HookAction
        do {
            hookAction = try HookAction.from(jsonData: bodyData)
        } catch {
            logger.error("Failed to parse hook body: \(error)")
            return emptyResponse()
        }

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
