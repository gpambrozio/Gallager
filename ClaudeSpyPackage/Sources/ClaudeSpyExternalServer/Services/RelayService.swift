import ClaudeSpyNetworking
import Foundation
import Logging

/// Routes messages between Mac and iOS devices
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let pushTokenStore: PushTokenStore
    private let apnsService: APNsService?
    private let logger = Logger(label: "relay-service")

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        pushTokenStore: PushTokenStore,
        apnsService: APNsService?
    ) {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
        self.pushTokenStore = pushTokenStore
        self.apnsService = apnsService
    }

    // MARK: - Connection Notifications

    /// Notify paired device of connection/disconnection
    func notifyConnection(pairId: String, deviceType: DeviceType, connected: Bool) async {
        let targetDevice: DeviceType = deviceType == .mac ? .ios : .mac

        let message: WebSocketMessage
        switch (deviceType, connected) {
        case (.mac, true):
            // Mac connected - notify iOS with Mac's public key
            let macKeyInfo = await pairingService.getMacPublicKey(pairId: pairId)
            let connectedMessage = DeviceConnectedMessage(
                publicKey: macKeyInfo?.key,
                publicKeyId: macKeyInfo?.keyId
            )
            message = .macConnected(connectedMessage)
        case (.mac, false):
            message = .macDisconnected
        case (.ios, true):
            // iOS connected - notify Mac with iOS's public key
            let iosKeyInfo = await pairingService.getIOSPublicKey(pairId: pairId)
            let connectedMessage = DeviceConnectedMessage(
                publicKey: iosKeyInfo?.key,
                publicKeyId: iosKeyInfo?.keyId
            )
            message = .iosConnected(connectedMessage)
        case (.ios, false):
            message = .iosDisconnected
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
            // Relay hook events to iOS via WebSocket
            logger.info("Relaying hook event to iOS", metadata: ["action": "\(event.event.action.eventName)"])
            await connectionHub.send(.hookEvent(event), to: pairId, deviceType: .ios)

            // Also try to send push notification (will only send if iOS is disconnected)
            await apnsService?.sendNotificationIfNeeded(for: event, pairId: pairId)

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

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages - server cannot decrypt
            logger.info("Relaying encrypted message to iOS", metadata: ["innerType": "\(encryptedMessage.innerType.rawValue)"])
            await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .ios)

        case let .encryptedPush(payload):
            // Encrypted push notification - forward to APNs if iOS is not connected
            logger.info("Received encrypted push payload")
            await apnsService?.sendEncryptedNotificationIfNeeded(payload: payload, pairId: pairId)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .mac)

        default:
            logger.debug("Unhandled Mac message type")
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
                logger.info("Relaying command to Mac", metadata: ["type": "\(command.command)"])
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

        case let .registerPushToken(tokenMessage):
            // Store push token for this pair
            logger.info("iOS registering push token", metadata: ["pairId": "\(pairId)"])
            await pushTokenStore.registerToken(tokenMessage.deviceToken, for: pairId)
            let response = PushTokenRegisteredMessage(success: true)
            await connectionHub.send(.pushTokenRegistered(response), to: pairId, deviceType: .ios)

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages to Mac - server cannot decrypt
            if await connectionHub.isMacConnected(pairId: pairId) {
                logger.info("Relaying encrypted message to Mac", metadata: ["innerType": "\(encryptedMessage.innerType.rawValue)"])
                await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .mac)
            } else {
                // Mac not connected - encrypted commands will fail
                logger.warning("Mac not connected, cannot relay encrypted command")
                // Note: We can't send a proper error response since we don't know the command ID
                // The iOS client will timeout and handle this case
            }

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .ios)

        default:
            logger.debug("Unhandled iOS message type")
        }
    }

    // MARK: - Registration Handlers

    private func handleMacRegistration(_ registration: RegisterMacMessage, pairId: String) async {
        // Store Mac's public key for the pair
        await pairingService.updateMacPublicKey(
            pairId: pairId,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )

        let iosDeviceName = await pairingService.getIOSDeviceName(pairId: pairId)
        let isIOSConnected = await connectionHub.isIOSConnected(pairId: pairId)

        // Get iOS public key if available
        let iosKeyInfo = await pairingService.getIOSPublicKey(pairId: pairId)

        logger.info("Mac registration complete", metadata: [
            "pairId": "\(pairId)",
            "iosConnected": "\(isIOSConnected)",
            "iosDeviceName": "\(iosDeviceName ?? "none")",
            "hasIOSPublicKey": "\(iosKeyInfo != nil)",
        ])

        let response = MacRegisteredMessage(
            success: true,
            iosDeviceName: iosDeviceName,
            iosPublicKey: iosKeyInfo?.key,
            iosPublicKeyId: iosKeyInfo?.keyId
        )

        await connectionHub.send(.macRegistered(response), to: pairId, deviceType: .mac)

        // Notify Mac if iOS is already connected
        if isIOSConnected {
            logger.info("Notifying Mac that iOS is connected")
            let connectedMessage = DeviceConnectedMessage(
                publicKey: iosKeyInfo?.key,
                publicKeyId: iosKeyInfo?.keyId
            )
            await connectionHub.send(.iosConnected(connectedMessage), to: pairId, deviceType: .mac)
        }
    }

    private func handleIOSRegistration(_ registration: RegisterIOSMessage, pairId: String) async {
        // Store iOS's public key for the pair
        await pairingService.updateIOSPublicKey(
            pairId: pairId,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )

        let macDeviceName = await pairingService.getMacDeviceName(pairId: pairId)
        let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)

        // Get Mac public key if available
        let macKeyInfo = await pairingService.getMacPublicKey(pairId: pairId)

        logger.info("iOS registration complete", metadata: [
            "pairId": "\(pairId)",
            "macConnected": "\(isMacConnected)",
            "macDeviceName": "\(macDeviceName ?? "none")",
            "hasMacPublicKey": "\(macKeyInfo != nil)",
        ])

        let response = IOSRegisteredMessage(
            success: true,
            macDeviceName: macDeviceName,
            macPublicKey: macKeyInfo?.key,
            macPublicKeyId: macKeyInfo?.keyId
        )

        await connectionHub.send(.iosRegistered(response), to: pairId, deviceType: .ios)

        // Notify iOS if Mac is already connected
        if isMacConnected {
            logger.info("Notifying iOS that Mac is connected, requesting session state")
            let connectedMessage = DeviceConnectedMessage(
                publicKey: macKeyInfo?.key,
                publicKeyId: macKeyInfo?.keyId
            )
            await connectionHub.send(.macConnected(connectedMessage), to: pairId, deviceType: .ios)
            // Also request current session state from Mac
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)
        }
    }
}
