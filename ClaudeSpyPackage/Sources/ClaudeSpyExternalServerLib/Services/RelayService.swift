import ClaudeSpyNetworking
import Foundation
import Logging

/// Routes messages between host and viewer devices
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let apnsService: APNsService?
    private let metricsService: MetricsService
    private let logger = Logger(label: "relay-service")

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        apnsService: APNsService?,
        metricsService: MetricsService
    ) {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
        self.apnsService = apnsService
        self.metricsService = metricsService
    }

    // MARK: - Connection Notifications

    /// Notify paired device of connection/disconnection
    func notifyConnection(pairId: String, deviceType: DeviceType, connected: Bool) async {
        let targetDevice: DeviceType = deviceType == .host ? .viewer : .host

        let message: WebSocketMessage
        switch (deviceType, connected) {
        case (.host, true):
            // Host connected - notify viewer with host's public key
            guard let hostKeyInfo = await pairingService.getHostPublicKey(pairId: pairId) else {
                logger.warning("Host connected but no public key available, skipping notification")
                return
            }
            let connectedMessage = ViewerConnectedMessage(
                publicKey: hostKeyInfo.key,
                publicKeyId: hostKeyInfo.keyId
            )
            message = .hostConnected(connectedMessage)
        case (.host, false):
            message = .hostDisconnected
        case (.viewer, true):
            // Viewer connected - notify host with viewer's public key
            guard let viewerKeyInfo = await pairingService.getViewerPublicKey(pairId: pairId) else {
                logger.warning("Viewer connected but no public key available, skipping notification")
                return
            }
            let connectedMessage = ViewerConnectedMessage(
                publicKey: viewerKeyInfo.key,
                publicKeyId: viewerKeyInfo.keyId
            )
            message = .viewerConnected(connectedMessage)
        case (.viewer, false):
            message = .viewerDisconnected
        }

        await connectionHub.send(message, to: pairId, deviceType: targetDevice)
    }

    // MARK: - Message Handling

    /// Handle incoming message from host
    func handleHostMessage(_ message: WebSocketMessage, pairId: String) async {
        logger.info("Host message received", metadata: ["pairId": "\(pairId)", "type": "\(message.messageType)"])

        switch message {
        case let .registerHost(registration):
            logger.info("Host registering", metadata: ["deviceId": "\(registration.deviceId)"])
            await handleHostRegistration(registration, pairId: pairId)

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages - server cannot decrypt or see message type
            await metricsService.incrementMessagesRelayed()
            logger.info("Relaying encrypted message to viewer")
            await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .viewer)

        case let .encryptedPush(payload):
            // Encrypted push notification - forward to APNs if viewer is not connected
            logger.info("Received encrypted push payload")
            await apnsService?.sendEncryptedNotificationIfNeeded(payload: payload, pairId: pairId)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .host)

        default:
            // All sensitive messages (hookEvent, sessionState, commandResponse, terminalStream)
            // must be sent encrypted. Reject unencrypted versions.
            logger.warning("Rejected unencrypted message that should be encrypted", metadata: ["type": "\(message.messageType)"])
        }
    }

    /// Handle incoming message from viewer
    func handleViewerMessage(_ message: WebSocketMessage, pairId: String) async {
        logger.info("Viewer message received", metadata: ["pairId": "\(pairId)", "type": "\(message.messageType)"])

        switch message {
        case let .registerViewer(registration):
            logger.info("Viewer registering", metadata: ["deviceId": "\(registration.deviceId)"])
            await handleViewerRegistration(registration, pairId: pairId)

        case .requestSessionState:
            // Forward request to host (this is a control message, not sensitive)
            let isHostConnected = await connectionHub.isHostConnected(pairId: pairId)
            logger.info("Viewer requesting session state", metadata: ["hostConnected": "\(isHostConnected)"])
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .host)

        case let .registerPushToken(tokenMessage):
            // Store push token for this pair
            logger.info("Viewer registering push token", metadata: ["pairId": "\(pairId)"])
            await pairingService.registerPushToken(tokenMessage.deviceToken, for: pairId)
            let response = PushTokenRegisteredMessage(success: true)
            await connectionHub.send(.pushTokenRegistered(response), to: pairId, deviceType: .viewer)

        case let .encrypted(encryptedMessage):
            // Pass through encrypted messages to host - server cannot decrypt or see message type
            if await connectionHub.isHostConnected(pairId: pairId) {
                await metricsService.incrementMessagesRelayed()
                logger.info("Relaying encrypted message to host")
                await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .host)
            } else {
                // Host not connected - encrypted commands will fail
                logger.warning("Host not connected, cannot relay encrypted command")
                // Note: We can't send a proper error response since we don't know the command ID
                // and can't encrypt the response. The viewer client will timeout and handle this case.
            }

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .viewer)

        default:
            // All sensitive messages (command) must be sent encrypted.
            // Reject unencrypted versions.
            logger.warning("Rejected unencrypted message that should be encrypted", metadata: ["type": "\(message.messageType)"])
        }
    }

    // MARK: - Registration Handlers

    private func handleHostRegistration(_ registration: RegisterHostMessage, pairId: String) async {
        // Store host's public key and username for the pair
        await pairingService.updateHostPublicKey(
            pairId: pairId,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId,
            username: registration.username
        )

        let viewerDeviceName = await pairingService.getViewerDeviceName(pairId: pairId)
        let isViewerConnected = await connectionHub.isViewerConnected(pairId: pairId)

        // Get viewer public key if available
        let viewerKeyInfo = await pairingService.getViewerPublicKey(pairId: pairId)

        logger.info("Host registration complete", metadata: [
            "pairId": "\(pairId)",
            "viewerConnected": "\(isViewerConnected)",
            "viewerDeviceName": "\(viewerDeviceName ?? "none")",
            "hasViewerPublicKey": "\(viewerKeyInfo != nil)",
        ])

        let response = HostRegisteredMessage(
            success: true,
            viewerDeviceName: viewerDeviceName,
            viewerPublicKey: viewerKeyInfo?.key,
            viewerPublicKeyId: viewerKeyInfo?.keyId
        )

        await connectionHub.send(.hostRegistered(response), to: pairId, deviceType: .host)

        // Always notify viewer that host has connected (with public key for E2EE)
        // This is needed because the initial notifyConnection is called before registration
        // when we don't have the public key yet
        let hostConnectedMessage = ViewerConnectedMessage(
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
        logger.info("Notifying viewer that host registered with public key")
        await connectionHub.send(.hostConnected(hostConnectedMessage), to: pairId, deviceType: .viewer)

        // Notify host if viewer is already connected (only if we have their public key)
        if isViewerConnected, let viewerKeyInfo {
            logger.info("Notifying host that viewer is connected, requesting session state")
            let connectedMessage = ViewerConnectedMessage(
                publicKey: viewerKeyInfo.key,
                publicKeyId: viewerKeyInfo.keyId
            )
            await connectionHub.send(.viewerConnected(connectedMessage), to: pairId, deviceType: .host)
            // Also request current session state from host
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .host)
        }
    }

    private func handleViewerRegistration(_ registration: RegisterViewerMessage, pairId: String) async {
        // Store viewer's public key for the pair
        await pairingService.updateViewerPublicKey(
            pairId: pairId,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )

        let hostDeviceName = await pairingService.getHostDeviceName(pairId: pairId)
        let hostUsername = await pairingService.getHostUsername(pairId: pairId)
        let isHostConnected = await connectionHub.isHostConnected(pairId: pairId)

        // Get host public key if available
        let hostKeyInfo = await pairingService.getHostPublicKey(pairId: pairId)

        logger.info("Viewer registration complete", metadata: [
            "pairId": "\(pairId)",
            "hostConnected": "\(isHostConnected)",
            "hostDeviceName": "\(hostDeviceName ?? "none")",
            "hasHostPublicKey": "\(hostKeyInfo != nil)",
        ])

        let response = ViewerRegisteredMessage(
            success: true,
            hostDeviceName: hostDeviceName,
            hostPublicKey: hostKeyInfo?.key,
            hostPublicKeyId: hostKeyInfo?.keyId,
            hostUsername: hostUsername
        )

        await connectionHub.send(.viewerRegistered(response), to: pairId, deviceType: .viewer)

        // Always notify host that viewer has connected (with public key for E2EE)
        // This is needed because the initial notifyConnection is called before registration
        // when we don't have the public key yet
        let viewerConnectedMessage = ViewerConnectedMessage(
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
        logger.info("Notifying host that viewer registered with public key")
        await connectionHub.send(.viewerConnected(viewerConnectedMessage), to: pairId, deviceType: .host)

        // Notify viewer if host is already connected (only if we have their public key)
        if isHostConnected, let hostKeyInfo {
            logger.info("Notifying viewer that host is connected, requesting session state")
            let connectedMessage = ViewerConnectedMessage(
                publicKey: hostKeyInfo.key,
                publicKeyId: hostKeyInfo.keyId
            )
            await connectionHub.send(.hostConnected(connectedMessage), to: pairId, deviceType: .viewer)
            // Also request current session state from host
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .host)
        }
    }
}
