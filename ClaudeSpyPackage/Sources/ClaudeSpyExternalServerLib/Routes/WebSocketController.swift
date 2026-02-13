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

        let pairingService = req.application.pairingService
        let connectionHub = req.application.connectionHub
        let relayService = req.application.relayService

        // CRITICAL: Set up message handlers BEFORE any `await` suspension point.
        //
        // On localhost (E2E tests), the client sends its registration message almost
        // instantly after the WebSocket upgrade completes. Every `await` creates a
        // suspension point where NIO can deliver the client's frame. If the handler
        // isn't registered yet, the frame is silently dropped.
        //
        // Each handler ensures the connection is registered BEFORE processing the
        // message. This guarantees connectionHub.send() can find the connection when
        // sending responses (e.g. hostRegistered). Without this, the response could
        // be silently dropped because Swift actors do not guarantee FIFO ordering
        // of enqueued jobs — register() and send() on the same actor can execute
        // in either order even if register() was enqueued first.
        ws.onText { ws, text in
            let data = Data(text.utf8)
            await handleIncomingMessage(
                data: data,
                ws: ws,
                pairId: pairId,
                deviceType: deviceType,
                deviceId: deviceId,
                connectionHub: connectionHub,
                relayService: relayService,
                logger: req.logger
            )
        }

        ws.onBinary { ws, buffer in
            let data = Data(buffer: buffer)
            await handleIncomingMessage(
                data: data,
                ws: ws,
                pairId: pairId,
                deviceType: deviceType,
                deviceId: deviceId,
                connectionHub: connectionHub,
                relayService: relayService,
                logger: req.logger
            )
        }

        ws.onClose.whenComplete { _ in
            Task {
                await connectionHub.unregister(pairId: pairId, deviceType: deviceType)
                await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: false)
                req.logger.info("WebSocket disconnected: \(deviceType) for pair \(pairId)")
            }
        }

        // Register connection. The message handlers above also register defensively
        // before processing each message, so this is not strictly required for
        // correctness — but it keeps the connection registered for the notifyConnection
        // call below even if no message has arrived yet.
        let connection = Connection(
            pairId: pairId,
            deviceType: deviceType,
            deviceId: deviceId,
            webSocket: ws
        )
        await connectionHub.register(connection)
        req.logger.info("WebSocket connected: \(deviceType) for pair \(pairId)")

        // Validate the pair (after registration so messages aren't lost)
        guard await pairingService.isValidPair(pairId: pairId) else {
            req.logger.warning("WebSocket connection rejected: invalid pairId \(pairId)")
            await connectionHub.unregister(pairId: pairId, deviceType: deviceType)
            let errorMessage = WebSocketMessage.error(.invalidPair())
            if let data = try? JSONEncoder().encode(errorMessage) {
                try? await ws.send(raw: data, opcode: .text)
            }
            try? await ws.close(code: .policyViolation)
            return
        }

        // Notify the other device
        await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: true)
    }
}

// MARK: - Message Handling

private func handleIncomingMessage(
    data: Data,
    ws: WebSocket,
    pairId: String,
    deviceType: DeviceType,
    deviceId: String,
    connectionHub: ConnectionHub,
    relayService: RelayService,
    logger: Logger
) async {
    // Ensure connection is registered before processing. This is critical because the
    // message handler may run before handleWebSocketUpgrade's register() call completes.
    // By registering here (sequentially, before relay processing), we guarantee that
    // connectionHub.send() will find the connection when sending responses like hostRegistered.
    let connection = Connection(pairId: pairId, deviceType: deviceType, deviceId: deviceId, webSocket: ws)
    await connectionHub.register(connection)

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
