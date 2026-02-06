import ClaudeSpyNetworking
import Vapor

/// Handles WebSocket connections for real-time communication
struct WebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Configure WebSocket with larger frame size (1MB) to handle terminal snapshots
        routes.webSocket("ws", maxFrameSize: .init(integerLiteral: 1 << 20), onUpgrade: handleWebSocketUpgrade)
    }

    /// Handle WebSocket upgrade
    /// WS /api/ws?pairId=xxx&deviceType=mac|ios&deviceId=xxx
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

        // Register connection
        let connection = Connection(
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

        // Handle disconnect
        ws.onClose.whenComplete { _ in
            Task {
                await connectionHub.unregister(pairId: pairId, deviceType: deviceType)
                await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: false)
                req.logger.info("WebSocket disconnected: \(deviceType) for pair \(pairId)")
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
        case .mac:
            await relayService.handleMacMessage(message, pairId: pairId)
        case .ios:
            await relayService.handleIOSMessage(message, pairId: pairId)
        case .macViewer:
            await relayService.handleMacViewerMessage(message, pairId: pairId)
        }
    } catch {
        logger.error("Failed to decode WebSocket message: \(error)")
    }
}

// MARK: - Device Type

enum DeviceType: String {
    case mac
    case ios
    case macViewer
}
