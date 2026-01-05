import ClaudeSpyNetworking
import Foundation

/// Routes messages between Mac and iOS devices
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub

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
        switch message {
        case let .registerMac(registration):
            await handleMacRegistration(registration, pairId: pairId)

        case let .hookEvent(event):
            // Relay hook events to iOS
            await connectionHub.send(.hookEvent(event), to: pairId, deviceType: .ios)

        case let .commandResponse(response):
            // Relay command responses to iOS
            await connectionHub.send(.commandResponse(response), to: pairId, deviceType: .ios)

        case let .sessionState(state):
            // Relay session state to iOS
            await connectionHub.send(.sessionState(state), to: pairId, deviceType: .ios)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .mac)

        default:
            break
        }
    }

    /// Handle incoming message from iOS
    func handleIOSMessage(_ message: WebSocketMessage, pairId: String) async {
        switch message {
        case let .registerIOS(registration):
            await handleIOSRegistration(registration, pairId: pairId)

        case let .command(command):
            // Relay commands to Mac
            if await connectionHub.isMacConnected(pairId: pairId) {
                await connectionHub.send(.command(command), to: pairId, deviceType: .mac)
            } else {
                // Mac not connected, send error back to iOS
                let errorResponse = CommandResponseMessage.failure(
                    for: command.id,
                    error: "Mac is not connected"
                )
                await connectionHub.send(.commandResponse(errorResponse), to: pairId, deviceType: .ios)
            }

        case .requestSessionState:
            // Forward request to Mac
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)

        case .ping:
            await connectionHub.send(.pong, to: pairId, deviceType: .ios)

        default:
            break
        }
    }

    // MARK: - Registration Handlers

    private func handleMacRegistration(_ registration: RegisterMacMessage, pairId: String) async {
        let iosDeviceName = await pairingService.getIOSDeviceName(pairId: pairId)
        let isIOSConnected = await connectionHub.isIOSConnected(pairId: pairId)

        let response = MacRegisteredMessage(
            success: true,
            iosDeviceName: iosDeviceName
        )

        await connectionHub.send(.macRegistered(response), to: pairId, deviceType: .mac)

        // Notify Mac if iOS is already connected
        if isIOSConnected {
            await connectionHub.send(.iosConnected, to: pairId, deviceType: .mac)
        }
    }

    private func handleIOSRegistration(_ registration: RegisterIOSMessage, pairId: String) async {
        let macDeviceName = await pairingService.getMacDeviceName(pairId: pairId)
        let isMacConnected = await connectionHub.isMacConnected(pairId: pairId)

        let response = IOSRegisteredMessage(
            success: true,
            macDeviceName: macDeviceName
        )

        await connectionHub.send(.iosRegistered(response), to: pairId, deviceType: .ios)

        // Notify iOS if Mac is already connected
        if isMacConnected {
            await connectionHub.send(.macConnected, to: pairId, deviceType: .ios)
            // Also request current session state from Mac
            await connectionHub.send(.requestSessionState, to: pairId, deviceType: .mac)
        }
    }
}
