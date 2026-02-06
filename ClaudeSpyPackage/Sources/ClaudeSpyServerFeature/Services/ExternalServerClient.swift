import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation
import Logging

/// Client for connecting to the external relay server via WebSocket.
///
/// Handles bidirectional communication between the host app and the relay server,
/// forwarding hook events to viewers and receiving commands from viewers.
@Observable
@MainActor
final public class ExternalServerClient {
    // MARK: - Connection State

    /// Current connection state
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case extendedBackoff
        case error(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var statusText: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting..."
            case .connected: "Connected"
            case let .reconnecting(attempt): "Reconnecting (\(attempt))..."
            case .extendedBackoff: "Reconnecting in 5 min..."
            case let .error(message): "Error: \(message)"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.externalserver")

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether a viewer is currently connected to the relay
    public private(set) var isViewerConnected = false

    /// Name of the connected viewer device (if known)
    public private(set) var connectedViewerDeviceName: String?

    /// The WebSocket task
    private var webSocketTask: URLSessionWebSocketTask?

    /// The URL session for WebSocket connections
    private var urlSession: URLSession?

    /// Pair ID for the current connection
    private var pairId: String?

    /// Device ID for registration
    private var deviceId: String?

    /// Device name for registration
    private var deviceName: String?

    /// Username of the host user
    private var username = ""

    /// Public key for E2EE (Base64-encoded)
    private var publicKey: String?

    /// Public key ID for E2EE
    private var publicKeyId: String?

    /// Server URL for reconnection
    private var serverURL: URL?

    /// Whether we should attempt reconnection
    private var shouldReconnect = false

    /// Current reconnection attempt
    private var reconnectionAttempt = 0

    /// Maximum reconnection attempts before entering extended backoff
    private let maxReconnectionAttempts = 10

    /// Extended backoff delay when max attempts reached (5 minutes)
    private let extendedBackoffDelay = 300

    /// Task for delayed reconnection (can be cancelled for immediate reconnect)
    private var reconnectionDelayTask: Task<Void, Never>?

    /// Task for receiving messages
    private var receiveTask: Task<Void, Never>?

    /// Task for ping/pong keep-alive
    private var pingTask: Task<Void, Never>?

    // MARK: - E2EE Properties

    /// E2EE service for encrypting/decrypting messages
    private var e2eeService: E2EEService?

    /// Partner's public key received during registration or connection (Base64-encoded)
    private var partnerPublicKey: String?

    /// Partner's public key ID
    private var partnerPublicKeyId: String?

    // MARK: - Callbacks

    /// Called when a command is received from viewer.
    /// Returns nil if the command sends its own response (e.g., snapshot commands send TerminalSnapshotMessage).
    private var onCommand: (@MainActor @Sendable (CommandMessage) async -> CommandResponseMessage?)?

    /// Called when session state is requested by viewer
    private var onSessionStateRequest: (@Sendable () async -> SessionStateMessage)?

    /// Called when connection state changes
    private var onConnectionStateChange: (@Sendable (ConnectionState) async -> Void)?

    /// Called when partner's public key is received (for persisting to settings)
    private var onPartnerKeyReceived: (@MainActor @Sendable (String, String) async -> Void)?

    // MARK: - Initialization

    public init() { }

    // MARK: - Configuration

    /// Set the handler for commands from viewer.
    /// Handler should return nil if it sends its own response (e.g., snapshot commands).
    public func setCommandHandler(
        _ handler: @escaping @Sendable (CommandMessage) async -> CommandResponseMessage?
    ) {
        onCommand = handler
    }

    /// Set the handler for session state requests
    public func setSessionStateHandler(
        _ handler: @escaping @Sendable () async -> SessionStateMessage
    ) {
        onSessionStateRequest = handler
    }

    /// Set the handler for connection state changes
    public func setConnectionStateHandler(
        _ handler: @escaping @Sendable (ConnectionState) async -> Void
    ) {
        onConnectionStateChange = handler
    }

    /// Set the handler for when partner's public key is received.
    /// Parameters are (publicKey: Base64, publicKeyId: String).
    public func setPartnerKeyHandler(
        _ handler: @escaping @MainActor @Sendable (String, String) async -> Void
    ) {
        onPartnerKeyReceived = handler
    }

    /// Proactively push current session state to viewer.
    /// Call this when the pane list changes (e.g., after creating a session).
    public func pushSessionState() async {
        guard state.isConnected, isViewerConnected else {
            logger.debug("Not connected to viewer, skipping session state push")
            return
        }

        guard let onSessionStateRequest else {
            logger.warning("Cannot push session state: no handler set")
            return
        }

        let sessionState = await onSessionStateRequest()
        logger.info("Pushing session state to viewer", metadata: [
            "pairId": "\(sessionState.pairId)",
            "sessionCount": "\(sessionState.sessions.count)",
            "paneCount": "\(sessionState.panes?.count ?? 0)",
        ])
        await sendEncrypted(.sessionState(sessionState))
    }

    // MARK: - Connection Management

    /// Connect to the external relay server
    /// - Parameters:
    ///   - serverURL: WebSocket URL of the relay server
    ///   - pairId: The pair ID from device pairing
    ///   - deviceId: Unique identifier for this host
    ///   - deviceName: Display name for this host
    ///   - username: Username of the host user (e.g., "john")
    ///   - publicKey: Base64-encoded public key for E2EE
    ///   - publicKeyId: Unique identifier for the public key
    ///   - e2eeService: E2EE service for encrypting/decrypting messages
    ///   - partnerPublicKey: Base64-encoded public key of the viewer (from pairing)
    ///   - partnerPublicKeyId: Unique identifier for the viewer's public key
    public func connect(
        serverURL: URL,
        pairId: String,
        deviceId: String,
        deviceName: String,
        username: String,
        publicKey: String,
        publicKeyId: String,
        e2eeService: E2EEService,
        partnerPublicKey: String? = nil,
        partnerPublicKeyId: String? = nil
    ) async {
        guard state != .connecting, !state.isConnected else {
            logger.warning("Already connected or connecting")
            return
        }

        self.serverURL = serverURL
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.username = username
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        self.e2eeService = e2eeService
        self.partnerPublicKey = partnerPublicKey
        self.partnerPublicKeyId = partnerPublicKeyId
        shouldReconnect = true
        reconnectionAttempt = 0

        // Establish E2EE session if we have partner's public key from pairing
        if let partnerKey = partnerPublicKey, let partnerKeyId = partnerPublicKeyId {
            guard let keyData = Data(base64Encoded: partnerKey) else {
                logger.error("Failed to decode partner public key from base64 - key may be malformed")
                // Continue without session - will be established when partner connects
                await performConnect()
                return
            }
            do {
                try await e2eeService.establishSession(
                    partnerPublicKey: keyData,
                    partnerKeyId: partnerKeyId,
                    pairId: pairId
                )
                logger.info("E2EE session established with partner from pairing info")
            } catch {
                logger.error("Failed to establish E2EE session: \(error)")
            }
        }

        await performConnect()
    }

    /// Disconnect from the relay server
    public func disconnect() async {
        shouldReconnect = false
        reconnectionDelayTask?.cancel()
        reconnectionDelayTask = nil
        await cleanupConnection()
        await updateState(.disconnected)
    }

    /// Attempt to reconnect immediately, cancelling any pending backoff.
    ///
    /// Call this when the system wakes from sleep or network becomes available
    /// to avoid waiting for the next scheduled reconnection attempt.
    public func reconnectImmediately() async {
        // Only reconnect if we should be connected but aren't
        guard shouldReconnect, !state.isConnected, state != .connecting else {
            logger.debug("reconnectImmediately: no action needed", metadata: [
                "shouldReconnect": "\(shouldReconnect)",
                "state": "\(state)",
            ])
            return
        }

        logger.info("Reconnecting immediately (e.g., system wake)")

        // Cancel any pending delayed reconnection
        reconnectionDelayTask?.cancel()
        reconnectionDelayTask = nil

        // Reset attempt counter for fresh start
        reconnectionAttempt = 0

        // Attempt connection now
        await performConnect()
    }

    // MARK: - Sending Messages

    /// Send a hook event to be relayed to viewer (encrypted)
    ///
    /// This also sends an encrypted push notification payload if the event
    /// would trigger a notification. The server uses the push payload to
    /// send a notification via APNs when viewer is not connected via WebSocket.
    public func sendHookEvent(_ event: HookEvent) async {
        guard state.isConnected, let pairId else {
            logger.debug("Not connected, cannot send hook event")
            return
        }

        let message = WebSocketMessage.hookEvent(
            HookEventMessage(pairId: pairId, event: event)
        )
        await sendEncrypted(message)

        // Also send encrypted push payload for notifications when iOS is offline
        await sendEncryptedPushNotification(for: event)
    }

    /// Send terminal stream data to viewer (encrypted)
    public func sendTerminalStream(_ streamMessage: TerminalStreamMessage) async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot send terminal stream")
            return
        }

        logger.debug("Sending terminal stream", metadata: [
            "paneId": "\(streamMessage.paneId)",
            "updateType": "\(streamMessage.updateType)",
        ])

        let message = WebSocketMessage.terminalStream(streamMessage)
        await sendEncrypted(message)
    }

    /// Send an encrypted push notification payload for a hook event.
    ///
    /// This is sent alongside the encrypted hook event. The server will:
    /// - Forward to APNs if viewer is not connected via WebSocket
    /// - Discard if viewer is already connected (they get the WebSocket message)
    ///
    /// The iOS Notification Service Extension decrypts the payload and displays
    /// the rich notification content.
    ///
    /// - Parameter event: The hook event that triggered the notification
    public func sendEncryptedPushNotification(for event: HookEvent) async {
        guard state.isConnected, let pairId else {
            logger.debug("Not connected, cannot send encrypted push")
            return
        }

        guard let e2eeService, await e2eeService.isSessionEstablished else {
            logger.error("E2EE session not established, cannot send encrypted push")
            return
        }

        // Build notification content from the event
        let eventMessage = HookEventMessage(pairId: pairId, event: event)
        guard let notification = eventMessage.buildNotification() else {
            logger.debug("Event does not trigger notification, skipping push")
            return
        }

        let content = NotificationContent(
            title: notification.title,
            body: notification.body,
            eventType: event.action.eventName,
            pairId: pairId,
            paneId: event.tmuxPane,
            timestamp: event.timestamp
        )

        do {
            // Encrypt the notification content
            let encryptedContent = try await e2eeService.encrypt(content)

            // Send the encrypted push payload
            let payload = EncryptedPushPayload(encryptedContent: encryptedContent, pairId: pairId)
            let message = WebSocketMessage.encryptedPush(payload)

            logger.info("Sending encrypted push notification", metadata: [
                "eventType": "\(event.action.eventName)",
            ])

            await send(message)
        } catch {
            logger.error("Failed to encrypt push notification: \(error)")
        }
    }

    // MARK: - Private Methods

    private func performConnect() async {
        // Guard against concurrent connection attempts (e.g., rapid wake notifications)
        guard state != .connecting, !state.isConnected else {
            logger.debug("performConnect: already connecting or connected, skipping")
            return
        }

        guard
            let serverURL, let pairId, let deviceId, let deviceName,
            let publicKey, let publicKeyId
        else {
            logger.error("Missing connection parameters")
            await updateState(.error("Missing connection parameters"))
            return
        }

        await updateState(.connecting)

        // Build WebSocket URL with query parameters
        // The server expects WebSocket connections at /api/ws
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)

        // Append /api/ws path if not already present
        var path = components?.path ?? ""
        if !path.hasSuffix("/api/ws") {
            if path.hasSuffix("/") {
                path += "api/ws"
            } else {
                path += "/api/ws"
            }
        }
        components?.path = path

        components?.queryItems = [
            URLQueryItem(name: "pairId", value: pairId),
            URLQueryItem(name: "deviceType", value: "host"),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]

        guard let wsURL = components?.url else {
            logger.error("Failed to build WebSocket URL")
            await updateState(.error("Invalid server URL"))
            return
        }

        logger.info("Connecting to relay server", metadata: ["url": "\(wsURL)"])

        // Create URL session with delegate for connection events
        let session = URLSession(configuration: .default)
        urlSession = session

        // Create and start WebSocket task
        let task = session.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        // Send registration message
        let registerMessage = WebSocketMessage.registerHost(
            RegisterHostMessage(
                pairId: pairId,
                deviceId: deviceId,
                deviceName: deviceName,
                publicKey: publicKey,
                publicKeyId: publicKeyId,
                username: username
            )
        )
        await send(registerMessage)

        // Start ping task for keep-alive
        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    private func receiveMessages() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else { break }

            do {
                let message = try await task.receive()
                await handleMessage(message)
            } catch {
                if !Task.isCancelled {
                    logger.error("WebSocket receive error: \(error)")
                    await handleDisconnection()
                }
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(messageData):
            data = messageData
        @unknown default:
            logger.warning("Unknown message type received")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let wsMessage = try decoder.decode(WebSocketMessage.self, from: data)
            await handleWebSocketMessage(wsMessage)
        } catch {
            logger.error("Failed to decode WebSocket message: \(error)")
        }
    }

    private func handleWebSocketMessage(_ message: WebSocketMessage) async {
        // Decrypt encrypted messages first
        let decryptedMessage: WebSocketMessage
        if case .encrypted = message {
            guard let e2eeService else {
                logger.error("Received encrypted message but E2EE service not configured")
                return
            }
            do {
                decryptedMessage = try await message.decrypt(using: e2eeService)
                logger.trace("Decrypted message", metadata: ["type": "\(decryptedMessage.messageType)"])
            } catch {
                logger.error("Failed to decrypt message: \(error)")
                return
            }
        } else {
            decryptedMessage = message
        }

        switch decryptedMessage {
        case let .hostRegistered(response):
            if response.success {
                logger.info("Successfully registered with relay server")
                await updateState(.connected)
                connectedViewerDeviceName = response.viewerDeviceName
                isViewerConnected = response.viewerDeviceName != nil

                // Establish E2EE session if viewer is connected and we have their public key
                if
                    let viewerPublicKey = response.viewerPublicKey,
                    let viewerPublicKeyId = response.viewerPublicKeyId,
                    let keyData = Data(base64Encoded: viewerPublicKey),
                    let e2eeService,
                    let pairId {
                    do {
                        try await e2eeService.establishSession(
                            partnerPublicKey: keyData,
                            partnerKeyId: viewerPublicKeyId,
                            pairId: pairId
                        )
                        partnerPublicKey = viewerPublicKey
                        partnerPublicKeyId = viewerPublicKeyId
                        logger.info("E2EE session established with viewer")

                        // Notify app to persist partner's public key
                        if let onPartnerKeyReceived {
                            await onPartnerKeyReceived(viewerPublicKey, viewerPublicKeyId)
                        }
                    } catch {
                        logger.error("Failed to establish E2EE session: \(error)")
                    }
                }
            } else {
                logger.error("Registration failed: \(response.error ?? "Unknown error")")
                await updateState(.error(response.error ?? "Registration failed"))
                await disconnect()
            }

        case let .command(command):
            logger.info("Received command from viewer", metadata: ["type": "\(command.command)"])
            if let onCommand, let response = await onCommand(command) {
                // Only send response if handler returned one.
                // Some commands (e.g., snapshot) send their own response type.
                await sendEncrypted(.commandResponse(response))
            }

        case let .viewerConnected(connectedMessage):
            logger.info("Viewer device connected")
            isViewerConnected = true

            // Establish E2EE session with viewer's public key
            let viewerPublicKey = connectedMessage.publicKey
            let viewerPublicKeyId = connectedMessage.publicKeyId
            if
                let keyData = Data(base64Encoded: viewerPublicKey),
                let e2eeService,
                let pairId {
                do {
                    try await e2eeService.establishSession(
                        partnerPublicKey: keyData,
                        partnerKeyId: viewerPublicKeyId,
                        pairId: pairId
                    )
                    partnerPublicKey = viewerPublicKey
                    partnerPublicKeyId = viewerPublicKeyId
                    logger.info("E2EE session established with viewer on connect notification")

                    // Notify app to persist partner's public key
                    if let onPartnerKeyReceived {
                        await onPartnerKeyReceived(viewerPublicKey, viewerPublicKeyId)
                    }
                } catch {
                    logger.error("Failed to establish E2EE session: \(error)")
                }
            }

            // Send current session state to newly connected viewer
            await pushSessionState()

        case .viewerDisconnected:
            logger.info("Viewer device disconnected")
            isViewerConnected = false
            connectedViewerDeviceName = nil

        case .requestSessionState:
            logger.info("Viewer requested session state")
            await pushSessionState()

        case .ping:
            await send(.pong)

        case .pong:
            // Expected response to our ping, no action needed
            break

        case let .error(errorMessage):
            logger.error("Server error: \(errorMessage.message)")
            if !errorMessage.recoverable {
                await updateState(.error(errorMessage.message))
                await disconnect()
            }

        default:
            logger.debug("Received unhandled message type")
        }
    }

    private func send(_ message: WebSocketMessage) async {
        guard let task = webSocketTask else {
            logger.debug("No WebSocket task, cannot send message")
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)
            logger.debug("Sending WebSocket message", metadata: [
                "type": "\(message.messageType)",
                "size": "\(data.count) bytes",
            ])
            try await task.send(.data(data))
            logger.debug("WebSocket message sent successfully")
        } catch {
            logger.error("Failed to send WebSocket message", metadata: [
                "type": "\(message.messageType)",
                "error": "\(error)",
            ])
        }
    }

    /// Encrypts and sends a message that should be encrypted.
    /// Fails closed if E2EE session is not established - will not send unencrypted.
    private func sendEncrypted(_ message: WebSocketMessage) async {
        // Fail closed: refuse to send if E2EE session is not established
        guard let e2eeService, await e2eeService.isSessionEstablished else {
            logger.error("E2EE session not established, refusing to send sensitive message")
            return
        }

        do {
            let encryptedMessage = try await message.encrypt(using: e2eeService)
            await send(encryptedMessage)
        } catch {
            logger.error("Failed to encrypt message: \(error)")
            // Don't send unencrypted as fallback - this would be a security issue
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled, state.isConnected {
            try? await Task.sleep(for: .seconds(30))
            if state.isConnected {
                await send(.ping)
            }
        }
    }

    private func handleDisconnection() async {
        isViewerConnected = false
        connectedViewerDeviceName = nil

        await cleanupConnection()

        guard shouldReconnect else { return }

        // Calculate delay based on attempt count
        let delay: Int
        if reconnectionAttempt < maxReconnectionAttempts {
            reconnectionAttempt += 1
            // Exponential backoff: 1s, 2s, 4s, 8s, etc. up to 60s
            delay = min(60, Int(pow(2, Double(reconnectionAttempt - 1))))
            await updateState(.reconnecting(attempt: reconnectionAttempt))
            logger.info("Reconnecting in \(delay) seconds (attempt \(reconnectionAttempt))")
        } else {
            // After max attempts, use extended backoff (5 minutes) and reset counter
            // This prevents giving up entirely while avoiding aggressive reconnection
            delay = extendedBackoffDelay
            logger.warning(
                "Max reconnection attempts reached, entering extended backoff (\(delay)s)"
            )
            await updateState(.extendedBackoff)
        }

        // Spawn reconnection in a new task - the current task was cancelled by cleanupConnection()
        // so we need a fresh task that won't have Task.isCancelled == true.
        // Store the task so it can be cancelled for immediate reconnection.
        reconnectionDelayTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Task was cancelled (e.g., by reconnectImmediately or disconnect)
                return
            }

            guard self.shouldReconnect else { return }

            // Reset attempt counter after extended backoff
            if self.reconnectionAttempt >= self.maxReconnectionAttempts {
                self.reconnectionAttempt = 0
                self.logger.info("Resetting reconnection attempt counter after extended backoff")
            }

            await self.performConnect()
        }
    }

    private func cleanupConnection() async {
        receiveTask?.cancel()
        receiveTask = nil

        pingTask?.cancel()
        pingTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func updateState(_ newState: ConnectionState) async {
        state = newState
        if let onConnectionStateChange {
            await onConnectionStateChange(newState)
        }
    }
}
