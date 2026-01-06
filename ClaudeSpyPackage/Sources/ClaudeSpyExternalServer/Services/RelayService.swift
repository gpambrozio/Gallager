import ClaudeSpyNetworking
import Foundation
import Logging

/// Routes messages between Mac and iOS devices
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let logger = Logger(label: "relay-service")

    init(pairingService: PairingService, connectionHub: ConnectionHub) {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
    }

    // MARK: - Connection Notifications

    /// Notify paired device of connection/disconnection
    func notifyConnection(pairId: String, deviceType: DeviceType, connected: Bool) async {
        let targetDevice: DeviceType = deviceType == .mac ? .ios : .mac

        let message: WebSocketMessage = switch (deviceType, connected) {
        case (.mac, true): .macConnected
        case (.mac, false): .macDisconnected
        case (.ios, true): .iosConnected
        case (.ios, false): .iosDisconnected
        }

        await connectionHub.send(message, to: pairId, deviceType: targetDevice)
    }

    // MARK: - Message Handling

    /// Handle incoming message from Mac
    func handleMacMessage(_ message: WebSocketMessage, pairId: String) async {
        logger.info("Mac message received", metadata: ["pairId": "\(pairId)", "type": "\(message.messageType)"])

        switch message {
        case let .registerMac(registration):
            logger.info("Mac registering", metadata: ["deviceId": "\(registration.deviceId)"])
            await handleMacRegistration(registration, pairId: pairId)

        case let .hookEvent(event):
            // Relay hook events to iOS
            logger.info("Relaying hook event to iOS", metadata: ["action": "\(event.event.action.eventName)"])
            await connectionHub.send(.hookEvent(event), to: pairId, deviceType: .ios)

        case let .commandResponse(response):
            // Relay command responses to iOS
            logger.info("Relaying command response to iOS")
            await connectionHub.send(.commandResponse(response), to: pairId, deviceType: .ios)

        case let .sessionState(state):
            // Relay session state to iOS
            logger.info("Relaying session state to iOS", metadata: ["sessions": "\(state.sessions.count)", "panes": "\(state.activePanes.count)"])
            await connectionHub.send(.sessionState(state), to: pairId, deviceType: .ios)

        case let .terminalSnapshot(snapshot):
            // Relay terminal snapshot to iOS
            logger.info("Relaying terminal snapshot to iOS", metadata: ["paneId": "\(snapshot.paneId)", "size": "\(snapshot.contentBase64.count)"])
            await connectionHub.send(.terminalSnapshot(snapshot), to: pairId, deviceType: .ios)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .mac)

        default:
            logger.debug("Unhandled Mac message type")
            break
        }
    }

    /// Handle incoming message from iOS
    func handleIOSMessage(_ message: WebSocketMessage, pairId: String) async {
        logger.info("iOS message received", metadata: ["pairId": "\(pairId)", "type": "\(message.messageType)"])

        switch message {
        case let .registerIOS(registration):
            logger.info("iOS registering", metadata: ["deviceId": "\(registration.deviceId)"])
            await handleIOSRegistration(registration, pairId: pairId)

        case let .command(command):
            // Relay commands to Mac
            if await connectionHub.isMacConnected(pairId: pairId) {
                logger.info("Relaying command to Mac", metadata: ["type": "\(command.type)"])
                await connectionHub.send(.command(command), to: pairId, deviceType: .mac)
            } else {
                // Mac not connected, send error back to iOS
                logger.warning("Mac not connected, cannot relay command")
                let errorResponse = CommandResponseMessage.failure(
                    for: command.id,
                    error: "Mac is not connected"
                )
                await connectionHub.send(.commandResponse(errorResponse), to: pairId, deviceType: .ios)
            }

        case .requestSessionState:
            // Forward request to Mac
            let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)
            logger.info("iOS requesting session state", metadata: ["macConnected": "\(isMacConnected)"])
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .ios)

        default:
            logger.debug("Unhandled iOS message type")
            break
        }
    }

    // MARK: - Registration Handlers

    private func handleMacRegistration(_ registration: RegisterMacMessage, pairId: String) async {
        let iosDeviceName = await pairingService.getIOSDeviceName(pairId: pairId)
        let isIOSConnected = await connectionHub.isIOSConnected(pairId: pairId)

        logger.info("Mac registration complete", metadata: [
            "pairId": "\(pairId)",
            "iosConnected": "\(isIOSConnected)",
            "iosDeviceName": "\(iosDeviceName ?? "none")"
        ])

        let response = MacRegisteredMessage(
            success: true,
            iosDeviceName: iosDeviceName
        )

        await connectionHub.send(.macRegistered(response), to: pairId, deviceType: .mac)

        // Notify Mac if iOS is already connected
        if isIOSConnected {
            logger.info("Notifying Mac that iOS is connected")
            await connectionHub.send(.iosConnected, to: pairId, deviceType: .mac)
        }
    }

    private func handleIOSRegistration(_ registration: RegisterIOSMessage, pairId: String) async {
        let macDeviceName = await pairingService.getMacDeviceName(pairId: pairId)
        let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)

        logger.info("iOS registration complete", metadata: [
            "pairId": "\(pairId)",
            "macConnected": "\(isMacConnected)",
            "macDeviceName": "\(macDeviceName ?? "none")"
        ])

        let response = IOSRegisteredMessage(
            success: true,
            macDeviceName: macDeviceName
        )

        await connectionHub.send(.iosRegistered(response), to: pairId, deviceType: .ios)

        // Notify iOS if Mac is already connected
        if isMacConnected {
            logger.info("Notifying iOS that Mac is connected, requesting session state")
            await connectionHub.send(.macConnected, to: pairId, deviceType: .ios)
            // Also request current session state from Mac
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)
        }
    }
}
