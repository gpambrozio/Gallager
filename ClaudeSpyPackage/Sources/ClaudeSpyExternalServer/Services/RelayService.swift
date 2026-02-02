import ClaudeSpyNetworking
import Foundation
import Logging

/// Routes messages between Mac and iOS devices
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let apnsService: APNsService?
    private let logger = Logger(label: "relay-service")

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        apnsService: APNsService?
    ) {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
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
            guard let macKeyInfo = await pairingService.getMacPublicKey(pairId: pairId) else {
                logger.warning("Mac connected but no public key available, skipping notification")
                return
            }
            let connectedMessage = DeviceConnectedMessage(
                publicKey: macKeyInfo.key,
                publicKeyId: macKeyInfo.keyId
            )
            message = .macConnected(connectedMessage)
        case (.mac, false):
            message = .macDisconnected
        case (.ios, true):
            // iOS connected - notify Mac with iOS's public key
            guard let iosKeyInfo = await pairingService.getIOSPublicKey(pairId: pairId) else {
                logger.warning("iOS connected but no public key available, skipping notification")
                return
            }
            let connectedMessage = DeviceConnectedMessage(
                publicKey: iosKeyInfo.key,
                publicKeyId: iosKeyInfo.keyId
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

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages - server cannot decrypt or see message type
            logger.info("Relaying encrypted message to iOS")
            await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .ios)

        case let .encryptedPush(payload):
            // Encrypted push notification - forward to APNs if iOS is not connected
            logger.info("Received encrypted push payload")
            await apnsService?.sendEncryptedNotificationIfNeeded(payload: payload, pairId: pairId)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .mac)

        default:
            // All sensitive messages (hookEvent, sessionState, commandResponse, terminalStream)
            // must be sent encrypted. Reject unencrypted versions.
            logger.warning("Rejected unencrypted message that should be encrypted", metadata: ["type": "\(message.messageType)"])
        }
    }

    /// Handle incoming message from iOS
    func handleIOSMessage(_ message: WebSocketMessage, pairId: String) async {
        logger.info("iOS message received", metadata: ["pairId": "\(pairId)", "type": "\(message.messageType)"])

        switch message {
        case let .registerIOS(registration):
            logger.info("iOS registering", metadata: ["deviceId": "\(registration.deviceId)"])
            await handleIOSRegistration(registration, pairId: pairId)

        case .requestSessionState:
            // Forward request to Mac (this is a control message, not sensitive)
            let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)
            logger.info("iOS requesting session state", metadata: ["macConnected": "\(isMacConnected)"])
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)

        case let .registerPushToken(tokenMessage):
            // Store push token for this pair
            logger.info("iOS registering push token", metadata: ["pairId": "\(pairId)"])
            await pairingService.registerPushToken(tokenMessage.deviceToken, for: pairId)
            let response = PushTokenRegisteredMessage(success: true)
            await connectionHub.send(.pushTokenRegistered(response), to: pairId, deviceType: .ios)

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages to Mac - server cannot decrypt or see message type
            if await connectionHub.isMacConnected(pairId: pairId) {
                logger.info("Relaying encrypted message to Mac")
                await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .mac)
            } else {
                // Mac not connected - encrypted commands will fail
                logger.warning("Mac not connected, cannot relay encrypted command")
                // Note: We can't send a proper error response since we don't know the command ID
                // and can't encrypt the response. The iOS client will timeout and handle this case.
            }

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .ios)

        default:
            // All sensitive messages (command) must be sent encrypted.
            // Reject unencrypted versions.
            logger.warning("Rejected unencrypted message that should be encrypted", metadata: ["type": "\(message.messageType)"])
        }
    }

    // MARK: - Registration Handlers

    private func handleMacRegistration(_ registration: RegisterMacMessage, pairId: String) async {
        // Store Mac's public key and username for the pair
        await pairingService.updateMacPublicKey(
            pairId: pairId,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId,
            username: registration.username
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

        // Always notify iOS that Mac has connected (with public key for E2EE)
        // This is needed because the initial notifyConnection is called before registration
        // when we don't have the public key yet
        let macConnectedMessage = DeviceConnectedMessage(
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
        logger.info("Notifying iOS that Mac registered with public key")
        await connectionHub.send(.macConnected(macConnectedMessage), to: pairId, deviceType: .ios)

        // Notify Mac if iOS is already connected (only if we have their public key)
        if isIOSConnected, let iosKeyInfo {
            logger.info("Notifying Mac that iOS is connected, requesting session state")
            let connectedMessage = DeviceConnectedMessage(
                publicKey: iosKeyInfo.key,
                publicKeyId: iosKeyInfo.keyId
            )
            await connectionHub.send(.iosConnected(connectedMessage), to: pairId, deviceType: .mac)
            // Also request current session state from Mac
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)
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
        let macUsername = await pairingService.getMacUsername(pairId: pairId)
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
            macPublicKeyId: macKeyInfo?.keyId,
            macUsername: macUsername
        )

        await connectionHub.send(.iosRegistered(response), to: pairId, deviceType: .ios)

        // Always notify Mac that iOS has connected (with public key for E2EE)
        // This is needed because the initial notifyConnection is called before registration
        // when we don't have the public key yet
        let iosConnectedMessage = DeviceConnectedMessage(
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
        logger.info("Notifying Mac that iOS registered with public key")
        await connectionHub.send(.iosConnected(iosConnectedMessage), to: pairId, deviceType: .mac)

        // Notify iOS if Mac is already connected (only if we have their public key)
        if isMacConnected, let macKeyInfo {
            logger.info("Notifying iOS that Mac is connected, requesting session state")
            let connectedMessage = DeviceConnectedMessage(
                publicKey: macKeyInfo.key,
                publicKeyId: macKeyInfo.keyId
            )
            await connectionHub.send(.macConnected(connectedMessage), to: pairId, deviceType: .ios)
            // Also request current session state from Mac
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)
        }
    }
}
