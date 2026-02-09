import ClaudeSpyNetworking
import Vapor

/// Handles WebSocket connections for real-time communication
struct WebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Configure WebSocket with larger frame size (1MB) to handle terminal snapshots
        routes.webSocket("ws", maxFrameSize: .init(integerLiteral: 1 << 20), onUpgrade: handleWebSocketUpgrade)
    }

    /// Handle WebSocket upgrade
    /// WS /api/ws?pairId=xxx&deviceType=host|viewer&deviceId=xxx
    @Sendable
    func handleWebSocketUpgrade(req: Request, ws: WebSocket) async {
        // Extract query parameters
        guard
            let pairId = req.query[String.self, at: "pairId"],
            let deviceTypeString = req.query[String.self, at: "deviceType"],
            let deviceType = DeviceType(rawValue: deviceTypeString),
            let deviceId = req.query[String.self, at: "deviceId"]
        else {
            req.logger.warning("WebSocket connection rejected: missing parameters")
            try? await ws.close(code: .policyViolation)
            return
        }

        // Validate pair exists
        let pairingService = req.application.pairingService
        guard await pairingService.isValidPair(pairId: pairId) else {
            req.logger.warning("WebSocket connection rejected: invalid pairId \(pairId)")
            let errorMessage = WebSocketMessage.error(.invalidPair())
            if let data = try? JSONEncoder().encode(errorMessage) {
                try? await ws.send(raw: data, opcode: .text)
            }
            try? await ws.close(code: .policyViolation)
            return
        }

        let connectionHub = req.application.connectionHub
        let relayService = req.application.relayService

        // Generate a unique ID for this connection instance to prevent stale close handlers
        // from unregistering newer connections during reconnect races.
        let connectionId = UUID()

        // Close any existing connection for this slot before registering the new one.
        // This ensures the old WebSocket is torn down, but we use connectionId-aware
        // unregister in the close handler so the old handler won't remove the new connection.
        if let existing = await connectionHub.getConnection(pairId: pairId, deviceType: deviceType) {
            req.logger.info("Closing stale \(deviceType) connection for pair \(pairId) before registering new one")
            try? await existing.webSocket.close(code: .goingAway)
        }

        // Register connection
        let connection = Connection(
            connectionId: connectionId,
            pairId: pairId,
            deviceType: deviceType,
            deviceId: deviceId,
            webSocket: ws
        )

        await connectionHub.register(connection)
        req.logger.info("WebSocket connected: \(deviceType) for pair \(pairId)")

        // Notify the other device
        await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: true)

        // Handle incoming messages
        ws.onText { _, text in
            let data = Data(text.utf8)
            await handleIncomingMessage(
                data: data,
                pairId: pairId,
                deviceType: deviceType,
                relayService: relayService,
                logger: req.logger
            )
        }

        ws.onBinary { _, buffer in
            let data = Data(buffer: buffer)
            await handleIncomingMessage(
                data: data,
                pairId: pairId,
                deviceType: deviceType,
                relayService: relayService,
                logger: req.logger
            )
        }

        // Handle disconnect - only unregister if this connection is still the current one.
        // This prevents a race where a stale close handler (from a replaced connection)
        // removes a newer connection that has already taken its place.
        ws.onClose.whenComplete { _ in
            Task {
                let didUnregister = await connectionHub.unregisterIfCurrent(
                    pairId: pairId,
                    deviceType: deviceType,
                    connectionId: connectionId
                )
                if didUnregister {
                    await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: false)
                    req.logger.info("WebSocket disconnected: \(deviceType) for pair \(pairId)")
                } else {
                    req.logger.info("Stale WebSocket close ignored: \(deviceType) for pair \(pairId) (superseded by newer connection)")
                }
            }
        }
    }
}

// MARK: - Message Handling

private func handleIncomingMessage(
    data: Data,
    pairId: String,
    deviceType: DeviceType,
    relayService: RelayService,
    logger: Logger
) async {
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(WebSocketMessage.self, from: data)

        switch deviceType {
        case .host:
            await relayService.handleHostMessage(message, pairId: pairId)
        case .viewer:
            await relayService.handleViewerMessage(message, pairId: pairId)
        }
    } catch {
        logger.error("Failed to decode WebSocket message: \(error)")
    }
}

// MARK: - Device Type

enum DeviceType: String {
    case host
    case viewer
}
