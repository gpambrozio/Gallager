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
        switch deviceType {
        case .mac:
            // Mac host connected/disconnected - notify iOS and Mac viewers
            if connected {
                guard let macKeyInfo = await pairingService.getMacPublicKey(pairId: pairId) else {
                    logger.warning("Mac connected but no public key available, skipping notification")
                    return
                }
                let connectedMessage = DeviceConnectedMessage(
                    publicKey: macKeyInfo.key,
                    publicKeyId: macKeyInfo.keyId
                )
                let message = WebSocketMessage.macConnected(connectedMessage)
                await connectionHub.send(message, to: pairId, deviceType: .ios)
                await connectionHub.send(message, to: pairId, deviceType: .macViewer)
            } else {
                await connectionHub.send(.macDisconnected, to: pairId, deviceType: .ios)
                await connectionHub.send(.macDisconnected, to: pairId, deviceType: .macViewer)
            }

        case .ios:
            // iOS connected - notify Mac with iOS's public key
            guard connected else {
                await connectionHub.send(.iosDisconnected, to: pairId, deviceType: .mac)
                return
            }
            guard let iosKeyInfo = await pairingService.getIOSPublicKey(pairId: pairId) else {
                logger.warning("iOS connected but no public key available, skipping notification")
                return
            }
            let connectedMessage = DeviceConnectedMessage(
                publicKey: iosKeyInfo.key,
                publicKeyId: iosKeyInfo.keyId
            )
            await connectionHub.send(.iosConnected(connectedMessage), to: pairId, deviceType: .mac)

        case .macViewer:
            // Mac viewer connected - notify Mac host with viewer's public key
            guard connected else {
                await connectionHub.send(.macViewerDisconnected, to: pairId, deviceType: .mac)
                return
            }
            guard let viewerKeyInfo = await pairingService.getMacViewerPublicKey(pairId: pairId) else {
                logger.warning("Mac viewer connected but no public key available, skipping notification")
                return
            }
            let connectedMessage = DeviceConnectedMessage(
                publicKey: viewerKeyInfo.key,
                publicKeyId: viewerKeyInfo.keyId
            )
            await connectionHub.send(.macViewerConnected(connectedMessage), to: pairId, deviceType: .mac)
        }
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
            // Relay to both iOS and Mac viewer devices
            logger.info("Relaying encrypted message to iOS and Mac viewers")
            await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .ios)
            await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .macViewer)

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

    /// Handle incoming message from Mac viewer (Mac acting as a viewer for another Mac)
    func handleMacViewerMessage(_ message: WebSocketMessage, pairId: String) async {
        logger.info("Mac viewer message received", metadata: ["pairId": "\(pairId)", "type": "\(message.messageType)"])

        switch message {
        case let .registerMacViewer(registration):
            logger.info("Mac viewer registering", metadata: ["deviceId": "\(registration.deviceId)"])
            await handleMacViewerRegistration(registration, pairId: pairId)

        case .requestSessionState:
            // Forward request to Mac host (this is a control message, not sensitive)
            let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)
            logger.info("Mac viewer requesting session state", metadata: ["macConnected": "\(isMacConnected)"])
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages to Mac host - server cannot decrypt or see message type
            if await connectionHub.isMacConnected(pairId: pairId) {
                logger.info("Relaying encrypted message from Mac viewer to Mac host")
                await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .mac)
            } else {
                logger.warning("Mac host not connected, cannot relay encrypted command from viewer")
            }

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .macViewer)

        default:
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
        logger.info("Notifying iOS and Mac viewers that Mac registered with public key")
        await connectionHub.send(.macConnected(macConnectedMessage), to: pairId, deviceType: .ios)
        await connectionHub.send(.macConnected(macConnectedMessage), to: pairId, deviceType: .macViewer)

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

    private func handleMacViewerRegistration(_ registration: RegisterMacViewerMessage, pairId: String) async {
        // Store Mac viewer's public key for the pair
        await pairingService.updateMacViewerPublicKey(
            pairId: pairId,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )

        let macDeviceName = await pairingService.getMacDeviceName(pairId: pairId)
        let macUsername = await pairingService.getMacUsername(pairId: pairId)
        let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)

        // Get Mac host public key if available
        let macKeyInfo = await pairingService.getMacPublicKey(pairId: pairId)

        logger.info("Mac viewer registration complete", metadata: [
            "pairId": "\(pairId)",
            "macConnected": "\(isMacConnected)",
            "macDeviceName": "\(macDeviceName ?? "none")",
            "hasMacPublicKey": "\(macKeyInfo != nil)",
        ])

        // Send registration response to Mac viewer (reuse same format as iOS)
        let response = MacViewerRegisteredMessage(
            success: true,
            macDeviceName: macDeviceName,
            macPublicKey: macKeyInfo?.key,
            macPublicKeyId: macKeyInfo?.keyId,
            macUsername: macUsername
        )

        await connectionHub.send(.macViewerRegistered(response), to: pairId, deviceType: .macViewer)

        // Notify Mac host that a Mac viewer has connected (with public key for E2EE)
        let viewerConnectedMessage = DeviceConnectedMessage(
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
        logger.info("Notifying Mac host that Mac viewer registered with public key")
        await connectionHub.send(.macViewerConnected(viewerConnectedMessage), to: pairId, deviceType: .mac)

        // Notify Mac viewer if Mac host is already connected (only if we have their public key)
        if isMacConnected, let macKeyInfo {
            logger.info("Notifying Mac viewer that Mac host is connected, requesting session state")
            let connectedMessage = DeviceConnectedMessage(
                publicKey: macKeyInfo.key,
                publicKeyId: macKeyInfo.keyId
            )
            await connectionHub.send(.macConnected(connectedMessage), to: pairId, deviceType: .macViewer)
            // Also request current session state from Mac host
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)
        }
    }
}
