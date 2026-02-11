import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation
import Logging

/// Represents a connection to a single paired viewer.
///
/// This wraps WebSocket communication with viewer-specific metadata and provides
/// a cleaner interface for managing individual viewer connections.
@Observable
@MainActor
final public class ConnectedViewer: Identifiable {
    // MARK: - Connection State

    /// Current connection state
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
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
            case let .error(message): "Error: \(message)"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.connectedviewer")

    /// Unique identifier (same as pairId)
    public let id: String

    /// The paired viewer's display name
    public var viewerName: String {
        pairedViewer.displayName
    }

    /// The paired viewer data
    public let pairedViewer: PairedViewer

    /// The E2EE service for this connection
    public let e2eeService: E2EEService

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether a viewer device is currently connected via WebSocket
    public private(set) var isViewerConnected = false

    /// Name of the connected viewer device (if known)
    public private(set) var connectedViewerDeviceName: String?

    // MARK: - Private Properties

    /// The WebSocket task
    private var webSocketTask: URLSessionWebSocketTask?

    /// The URL session for WebSocket connections
    private var urlSession: URLSession?

    /// Device ID for registration
    private var hostDeviceId = ""

    /// Device name for registration
    private var hostDeviceName = ""

    /// Username of the host user
    private var username = ""

    /// Public key for E2EE (Base64-encoded)
    private var publicKey = ""

    /// Public key ID for E2EE
    private var publicKeyId = ""

    /// Server URL for reconnection
    private var serverURL: URL?

    /// Whether we should attempt reconnection
    private var shouldReconnect = false

    /// Current reconnection attempt
    private var reconnectionAttempt = 0

    /// Maximum backoff delay in seconds (capped exponential backoff)
    private let maxBackoffDelay = 60

    /// Task for delayed reconnection
    private var reconnectionDelayTask: Task<Void, Never>?

    /// Task for receiving messages
    private var receiveTask: Task<Void, Never>?

    /// Task for ping/pong keep-alive
    private var pingTask: Task<Void, Never>?

    /// Partner's public key received during registration or connection (Base64-encoded)
    private var partnerPublicKey: String

    /// Partner's public key ID
    private var partnerPublicKeyId: String

    // MARK: - Callbacks

    /// Called when a command is received from viewer
    public var onCommand: (@MainActor @Sendable (CommandMessage) async -> CommandResponseMessage?)?

    /// Called when session state is requested by viewer
    public var onSessionStateRequest: (@Sendable () async -> SessionStateMessage)?

    /// Called when connection state changes
    public var onConnectionStateChange: (@Sendable (ConnectionState) async -> Void)?

    /// Called when partner's public key is received (for persisting to settings)
    public var onPartnerKeyReceived: (@MainActor @Sendable (String, String) async -> Void)?

    // MARK: - Initialization

    /// Creates a new viewer connection.
    ///
    /// - Parameters:
    ///   - pairedViewer: The paired viewer configuration
    ///   - e2eeService: The E2EE service for this connection (pre-configured with partner key)
    public init(pairedViewer: PairedViewer, e2eeService: E2EEService) {
        self.id = pairedViewer.id
        self.pairedViewer = pairedViewer
        self.e2eeService = e2eeService
        self.partnerPublicKey = pairedViewer.partnerPublicKey
        self.partnerPublicKeyId = pairedViewer.partnerPublicKeyId
    }

    // MARK: - Connection Management

    /// Connect to this viewer via the relay server.
    ///
    /// - Parameters:
    ///   - serverURL: The relay server URL
    ///   - deviceId: This host's identifier
    ///   - deviceName: This host's display name
    ///   - username: Username of the host user
    ///   - publicKey: This host's public key (Base64)
    ///   - publicKeyId: This host's public key ID
    public func connect(
        serverURL: URL,
        deviceId: String,
        deviceName: String,
        username: String,
        publicKey: String,
        publicKeyId: String
    ) async {
        guard state != .connecting, !state.isConnected else {
            logger.warning("Already connected or connecting to viewer: \(viewerName)")
            return
        }

        self.serverURL = serverURL
        hostDeviceId = deviceId
        hostDeviceName = deviceName
        self.username = username
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        shouldReconnect = true
        reconnectionAttempt = 0

        // Establish E2EE session if we have partner's public key from pairing
        if !partnerPublicKey.isEmpty {
            await establishE2EEWithPartner(publicKey: partnerPublicKey, keyId: partnerPublicKeyId)
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

    /// Immediately attempt to reconnect
    public func reconnectImmediately() async {
        guard shouldReconnect, !state.isConnected, state != .connecting else {
            return
        }

        logger.info("Reconnecting immediately to viewer: \(viewerName)")

        reconnectionDelayTask?.cancel()
        reconnectionDelayTask = nil
        reconnectionAttempt = 0

        await performConnect()
    }

    // MARK: - Sending Messages

    /// Send a hook event to be relayed to viewer (encrypted)
    public func sendHookEvent(_ event: HookEvent) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send hook event")
            return
        }

        let message = WebSocketMessage.hookEvent(
            HookEventMessage(pairId: id, event: event)
        )
        await sendEncrypted(message)

        // Also send encrypted push payload for notifications when iOS is offline
        await sendEncryptedPushNotification(for: event)
    }

    /// Send terminal stream data to viewer (encrypted)
    public func sendTerminalStream(_ streamMessage: TerminalStreamMessage) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send terminal stream")
            return
        }

        let message = WebSocketMessage.terminalStream(streamMessage)
        await sendEncrypted(message)
    }

    /// Proactively push current session state to viewer
    public func pushSessionState() async {
        guard state.isConnected, isViewerConnected else {
            logger.debug("Not connected to viewer, skipping session state push")
            return
        }

        guard let onSessionStateRequest else {
            logger.warning("Cannot push session state: no handler set")
            return
        }

        var sessionState = await onSessionStateRequest()
        // Set the pairId for this specific connection
        sessionState = SessionStateMessage(
            pairId: id,
            sessions: sessionState.sessions,
            activePanes: sessionState.activePanes,
            panes: sessionState.panes,
            claudeProjects: sessionState.claudeProjects
        )
        logger.info("Pushing session state to viewer: \(viewerName)")
        await sendEncrypted(.sessionState(sessionState))
    }

    // MARK: - Private Connection Methods

    private func performConnect() async {
        guard state != .connecting, !state.isConnected else {
            return
        }

        guard let serverURL else {
            logger.error("Missing server URL")
            await updateState(.error("Missing server URL"))
            return
        }

        await updateState(.connecting)

        // Build WebSocket URL with query parameters
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)

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
            URLQueryItem(name: "pairId", value: id),
            URLQueryItem(name: "deviceType", value: "host"),
            URLQueryItem(name: "deviceId", value: hostDeviceId),
        ]

        guard let wsURL = components?.url else {
            logger.error("Failed to build WebSocket URL")
            await updateState(.error("Invalid server URL"))
            return
        }

        logger.info("Connecting to relay server for viewer: \(viewerName)", metadata: ["url": "\(wsURL)"])

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        // Send registration message
        let registerMessage = WebSocketMessage.registerHost(
            RegisterHostMessage(
                pairId: id,
                deviceId: hostDeviceId,
                deviceName: hostDeviceName,
                publicKey: publicKey,
                publicKeyId: publicKeyId,
                username: username
            )
        )
        await send(registerMessage)

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
                    logger.error("WebSocket receive error for \(viewerName): \(error)")
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
                logger.info("Successfully registered with relay server for viewer: \(viewerName)")
                reconnectionAttempt = 0
                await updateState(.connected)
                connectedViewerDeviceName = response.viewerDeviceName
                isViewerConnected = response.viewerDeviceName != nil

                // Establish E2EE session if viewer is connected and we have their public key
                if
                    let viewerPublicKey = response.viewerPublicKey,
                    let viewerPublicKeyId = response.viewerPublicKeyId {
                    await establishE2EEWithPartner(publicKey: viewerPublicKey, keyId: viewerPublicKeyId)
                }
            } else {
                logger.error("Registration failed: \(response.error ?? "Unknown error")")
                await updateState(.error(response.error ?? "Registration failed"))
                await disconnect()
            }

        case let .command(command):
            logger.info("Received command from viewer", metadata: ["type": "\(command.command)"])
            if let onCommand, let response = await onCommand(command) {
                await sendEncrypted(.commandResponse(response))
            }

        case let .viewerConnected(connectedMessage):
            logger.info("Viewer device connected")
            isViewerConnected = true

            await establishE2EEWithPartner(
                publicKey: connectedMessage.publicKey,
                keyId: connectedMessage.publicKeyId
            )

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

    /// Establish an E2EE session with the partner's public key.
    ///
    /// Updates local state and notifies via callback on success.
    ///
    /// - Parameters:
    ///   - publicKey: Base64-encoded public key
    ///   - keyId: Public key identifier
    /// - Returns: Whether the session was established successfully
    @discardableResult
    private func establishE2EEWithPartner(publicKey: String, keyId: String) async -> Bool {
        guard let keyData = Data(base64Encoded: publicKey) else {
            logger.error("Failed to decode partner public key from base64")
            return false
        }

        do {
            try await e2eeService.establishSession(
                partnerPublicKey: keyData,
                partnerKeyId: keyId,
                pairId: id
            )
            partnerPublicKey = publicKey
            partnerPublicKeyId = keyId
            logger.info("E2EE session established with viewer")

            if let onPartnerKeyReceived {
                await onPartnerKeyReceived(publicKey, keyId)
            }
            return true
        } catch {
            logger.error("Failed to establish E2EE session: \(error)")
            return false
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
            try await task.send(.data(data))
        } catch {
            logger.error("Failed to send WebSocket message: \(error)")
        }
    }

    private func sendEncrypted(_ message: WebSocketMessage) async {
        guard await e2eeService.isSessionEstablished else {
            logger.error("E2EE session not established, refusing to send sensitive message")
            return
        }

        do {
            let encryptedMessage = try await message.encrypt(using: e2eeService)
            await send(encryptedMessage)
        } catch {
            logger.error("Failed to encrypt message: \(error)")
        }
    }

    private func sendEncryptedPushNotification(for event: HookEvent) async {
        guard state.isConnected else {
            return
        }

        guard await e2eeService.isSessionEstablished else {
            logger.error("E2EE session not established, cannot send encrypted push")
            return
        }

        let eventMessage = HookEventMessage(pairId: id, event: event)
        guard let notification = eventMessage.buildNotification() else {
            return
        }

        let content = NotificationContent(
            title: notification.title,
            body: notification.body,
            eventType: event.action.eventName,
            pairId: id,
            paneId: event.tmuxPane,
            timestamp: event.timestamp
        )

        do {
            let encryptedContent = try await e2eeService.encrypt(content)
            let payload = EncryptedPushPayload(encryptedContent: encryptedContent, pairId: id)
            let message = WebSocketMessage.encryptedPush(payload)
            await send(message)
        } catch {
            logger.error("Failed to encrypt push notification: \(error)")
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

        reconnectionAttempt += 1
        // Exponential backoff: 1s, 2s, 4s, 8s, ... capped at maxBackoffDelay
        let exponent = min(reconnectionAttempt - 1, 20)
        let delay = min(maxBackoffDelay, Int(pow(2, Double(exponent))))
        await updateState(.reconnecting(attempt: reconnectionAttempt))
        logger.info("Reconnecting to \(viewerName) in \(delay)s (attempt \(reconnectionAttempt))")

        reconnectionDelayTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard !Task.isCancelled, self.shouldReconnect else { return }

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
