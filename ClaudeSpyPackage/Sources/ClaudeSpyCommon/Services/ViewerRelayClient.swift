import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Errors that can occur during viewer relay communication.
public enum ViewerRelayClientError: Error, LocalizedError {
    case notConnected
    case timeout
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to relay server"
        case .timeout:
            return "Request timed out"
        case let .commandFailed(message):
            return "Command failed: \(message)"
        }
    }
}

/// Client for connecting to a remote host via the external relay server as a "viewer" device.
///
/// This is the shared implementation used by both macOS (`HostRelayClient`) and iOS (`RelayClient`)
/// to connect to the relay server, register as a viewer, and exchange encrypted messages with a host.
@Observable
@MainActor
final public class ViewerRelayClient {
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
            case let .reconnecting(attempt): "Backoff (\(attempt))..."
            case let .error(message): "Error: \(message)"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.viewerrelayclient")

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether the host is currently connected to the relay
    public private(set) var isHostConnected = false

    /// Name of the connected host device (if known)
    public private(set) var connectedHostName: String?

    /// The WebSocket task
    private var webSocketTask: URLSessionWebSocketTask?

    /// The URL session for WebSocket connections
    private var urlSession: URLSession?

    /// Pair ID for the current connection
    private var pairId: String?

    /// Device ID for registration (this device as viewer)
    private var deviceId: String?

    /// Device name for registration (this device as viewer)
    private var deviceName: String?

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

    /// Maximum reconnection attempts before giving up
    private let maxReconnectionAttempts = 10

    /// Task for receiving messages
    private var receiveTask: Task<Void, Never>?

    /// Task for ping/pong keep-alive
    private var pingTask: Task<Void, Never>?

    /// Task for delayed reconnection (exponential backoff)
    private var reconnectionTask: Task<Void, Never>?

    // MARK: - E2EE Properties

    /// E2EE service for encrypting/decrypting messages
    private var e2eeService: E2EEService?

    /// Partner's public key received during registration or connection (Base64-encoded)
    private var partnerPublicKey: String?

    /// Partner's public key ID
    private var partnerPublicKeyId: String?

    // MARK: - Pending Commands

    /// Type-erased response handlers keyed by command ID.
    private var pendingCommands: [UUID: @MainActor (Result<Any, Error>) -> Void] = [:]

    /// Timeout tasks keyed by command ID (for cancellation on response).
    /// These MUST be cancelled when responses arrive to prevent timeout handlers
    /// from firing after successful responses (race condition bug fix from iOS client).
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Callbacks

    /// Called when a hook event is received from host
    public var onHookEvent: (@Sendable (HookEventMessage) -> Void)?

    /// Called when session state is received from host
    public var onSessionState: (@Sendable (SessionStateMessage) -> Void)?

    /// Called when a terminal stream message is received from host
    public var onTerminalStream: (@MainActor @Sendable (TerminalStreamMessage) -> Void)?

    /// Called when partner's public key is received (for persisting to settings)
    public var onPartnerKeyReceived: (@MainActor @Sendable (String, String) async -> Void)?

    // MARK: - Initialization

    public init() { }

    // MARK: - Connection Management

    /// Connect to a remote host via the relay server.
    ///
    /// - Parameters:
    ///   - serverURL: WebSocket URL of the relay server
    ///   - pairId: The pair ID from device pairing
    ///   - deviceId: Unique identifier for this device (as viewer)
    ///   - deviceName: Display name for this device
    ///   - publicKey: Base64-encoded public key for E2EE
    ///   - publicKeyId: Unique identifier for the public key
    ///   - e2eeService: E2EE service for encrypting/decrypting messages
    ///   - partnerPublicKey: Base64-encoded public key of the host (from pairing)
    ///   - partnerPublicKeyId: Unique identifier for the host's public key
    public func connect(
        serverURL: URL,
        pairId: String,
        deviceId: String,
        deviceName: String,
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
                let errorMessage = "Failed to decode partner public key - encryption setup failed"
                logger.error("\(errorMessage)")
                state = .error(errorMessage)
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
                let errorMessage = "Failed to establish E2EE session: \(error.localizedDescription)"
                logger.error("\(errorMessage)")
                state = .error(errorMessage)
                return
            }
        }

        await performConnect()
    }

    /// Disconnect from the relay server
    public func disconnect() async {
        shouldReconnect = false
        await cleanupConnection()
        state = .disconnected
    }

    /// Reset reconnection backoff and immediately attempt to reconnect.
    public func reconnectImmediately() async {
        guard shouldReconnect else {
            logger.debug("Not configured to reconnect, ignoring reconnectImmediately()")
            return
        }

        guard !state.isConnected, state != .connecting else {
            logger.debug("Already connected or connecting, ignoring reconnectImmediately()")
            return
        }

        logger.info("Immediate reconnection requested, cancelling pending backoff and resetting")

        reconnectionTask?.cancel()
        reconnectionTask = nil

        reconnectionAttempt = 0
        await performConnect()
    }

    // MARK: - Sending Messages

    /// Send a command and wait for response with type-safe return type.
    ///
    /// - Parameters:
    ///   - command: The command specification to send (conforms to `CommandSpec`)
    ///   - paneId: The tmux pane ID to target
    ///   - timeout: Maximum time to wait for response (default: 15 seconds)
    /// - Returns: Result containing the command's associated Response type or Error
    public func sendCommand<C: CommandSpec>(
        _ command: C,
        paneId: String,
        timeout: TimeInterval = 15
    ) async -> Result<C.Response, Error> {
        guard state.isConnected else {
            return .failure(ViewerRelayClientError.notConnected)
        }

        let commandMessage = CommandMessage(paneId: paneId, command: command.commandType)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<C.Response, Error>, Never>) in
            pendingCommands[commandMessage.id] = { result in
                switch result {
                case let .success(anyResponse):
                    if let typedResponse = anyResponse as? C.Response {
                        continuation.resume(returning: .success(typedResponse))
                    } else {
                        continuation.resume(returning: .failure(ViewerRelayClientError.commandFailed("Unexpected response type")))
                    }
                case let .failure(error):
                    continuation.resume(returning: .failure(error))
                }
            }

            Task {
                await self.sendEncrypted(.command(commandMessage))
            }

            let commandId = commandMessage.id
            timeoutTasks[commandId] = Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.timeoutTasks.removeValue(forKey: commandId)
                if let handler = self.pendingCommands.removeValue(forKey: commandId) {
                    handler(.failure(ViewerRelayClientError.timeout))
                }
            }
        }
    }

    /// Request current session state from host
    public func requestSessionState() async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot request session state")
            return
        }

        await send(.requestSessionState)
    }

    /// Send push notification token to the relay server (iOS only).
    ///
    /// - Parameter token: The APNs device token as a hex string
    public func sendPushToken(_ token: String) async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot send push token")
            return
        }

        logger.info("Sending push token to relay server")
        let message = WebSocketMessage.registerPushToken(RegisterPushTokenMessage(deviceToken: token))
        await send(message)
    }

    // MARK: - Private Methods

    private func performConnect() async {
        guard
            let serverURL, let pairId, let deviceId, let deviceName,
            let publicKey, let publicKeyId
        else {
            logger.error("Missing connection parameters")
            state = .error("Missing connection parameters")
            return
        }

        state = .connecting

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
            URLQueryItem(name: "pairId", value: pairId),
            URLQueryItem(name: "deviceType", value: "viewer"),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]

        guard let wsURL = components?.url else {
            logger.error("Failed to build WebSocket URL")
            state = .error("Invalid server URL")
            return
        }

        logger.info("Connecting to relay server as viewer: \(wsURL)")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        // Register as viewer
        let registerMessage = WebSocketMessage.registerViewer(
            RegisterViewerMessage(
                pairId: pairId,
                deviceId: deviceId,
                deviceName: deviceName,
                publicKey: publicKey,
                publicKeyId: publicKeyId
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
                logger.trace("Decrypted message: \(decryptedMessage.messageType)")
            } catch {
                logger.error("Failed to decrypt message: \(error)")
                return
            }
        } else {
            decryptedMessage = message
        }

        switch decryptedMessage {
        case let .viewerRegistered(response):
            if response.success {
                logger.info("Successfully registered with relay server as viewer")
                state = .connected
                connectedHostName = response.hostDeviceName
                isHostConnected = response.hostDeviceName != nil

                // Establish E2EE session if host is connected and we have their public key
                if
                    let hostPublicKey = response.hostPublicKey,
                    let hostPublicKeyId = response.hostPublicKeyId,
                    let keyData = Data(base64Encoded: hostPublicKey),
                    let e2eeService,
                    let pairId {
                    do {
                        try await e2eeService.establishSession(
                            partnerPublicKey: keyData,
                            partnerKeyId: hostPublicKeyId,
                            pairId: pairId
                        )
                        partnerPublicKey = hostPublicKey
                        partnerPublicKeyId = hostPublicKeyId
                        logger.info("E2EE session established with host")

                        if let onPartnerKeyReceived {
                            await onPartnerKeyReceived(hostPublicKey, hostPublicKeyId)
                        }
                    } catch {
                        logger.error("Failed to establish E2EE session: \(error)")
                    }
                }

                // Request session state if host is connected
                if isHostConnected {
                    await requestSessionState()
                }
            } else {
                logger.error("Registration failed: \(response.error ?? "Unknown error")")
                state = .error(response.error ?? "Registration failed")
                await disconnect()
            }

        case let .hookEvent(event):
            logger.info("Received hook event from host")
            onHookEvent?(event)

        case let .sessionState(sessionState):
            logger.info("Received session state from host")
            onSessionState?(sessionState)

        case let .commandResponse(response):
            logger.info("Received command response from host")
            timeoutTasks[response.commandId]?.cancel()
            timeoutTasks.removeValue(forKey: response.commandId)
            if let handler = pendingCommands.removeValue(forKey: response.commandId) {
                if response.success {
                    handler(.success(response))
                } else {
                    handler(.failure(ViewerRelayClientError.commandFailed(response.error ?? "Unknown error")))
                }
            }

        case let .terminalStream(streamMessage):
            logger.trace("Received terminal stream for pane \(streamMessage.paneId)")
            onTerminalStream?(streamMessage)

        case let .hostConnected(connectedMessage):
            logger.info("Host device connected")
            isHostConnected = true

            let hostPublicKey = connectedMessage.publicKey
            let hostPublicKeyId = connectedMessage.publicKeyId
            if
                let keyData = Data(base64Encoded: hostPublicKey),
                let e2eeService,
                let pairId {
                do {
                    try await e2eeService.establishSession(
                        partnerPublicKey: keyData,
                        partnerKeyId: hostPublicKeyId,
                        pairId: pairId
                    )
                    partnerPublicKey = hostPublicKey
                    partnerPublicKeyId = hostPublicKeyId
                    logger.info("E2EE session established with host on connect notification")

                    if let onPartnerKeyReceived {
                        await onPartnerKeyReceived(hostPublicKey, hostPublicKeyId)
                    }
                } catch {
                    logger.error("Failed to establish E2EE session: \(error)")
                }
            }

            await requestSessionState()

        case .hostDisconnected:
            logger.info("Host device disconnected")
            isHostConnected = false
            connectedHostName = nil

        case .ping:
            await send(.pong)

        case .pong:
            break

        case let .pushTokenRegistered(response):
            if response.success {
                logger.info("Push token registered successfully with server")
            } else {
                logger.error("Failed to register push token: \(response.error ?? "Unknown error")")
            }

        case let .error(errorMessage):
            logger.error("Server error: \(errorMessage.message)")
            if !errorMessage.recoverable {
                state = .error(errorMessage.message)
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
            try await task.send(.data(data))
        } catch {
            logger.error("Failed to send WebSocket message: \(error)")
        }
    }

    /// Encrypts and sends a message that should be encrypted.
    /// Fails closed if E2EE session is not established - will not send unencrypted.
    private func sendEncrypted(_ message: WebSocketMessage) async {
        guard let e2eeService, await e2eeService.isSessionEstablished else {
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

    private func pingLoop() async {
        while !Task.isCancelled, state.isConnected {
            try? await Task.sleep(for: .seconds(30))
            if state.isConnected {
                await send(.ping)
            }
        }
    }

    private func handleDisconnection() async {
        isHostConnected = false
        connectedHostName = nil

        await cleanupConnection()

        if shouldReconnect, reconnectionAttempt < maxReconnectionAttempts {
            reconnectionAttempt += 1
            let currentAttempt = reconnectionAttempt
            state = .reconnecting(attempt: currentAttempt)

            let delay = min(60, Int(pow(2, Double(currentAttempt - 1))))
            logger.info("Reconnecting in \(delay) seconds (attempt \(currentAttempt))")

            reconnectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))

                guard
                    !Task.isCancelled,
                    let self,
                    self.shouldReconnect
                else { return }

                await self.performConnect()
            }
        } else if shouldReconnect {
            logger.error("Max reconnection attempts reached")
            state = .error("Connection lost after \(maxReconnectionAttempts) attempts")
        }
    }

    private func cleanupConnection() async {
        receiveTask?.cancel()
        receiveTask = nil

        pingTask?.cancel()
        pingTask = nil

        reconnectionTask?.cancel()
        reconnectionTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil

        for (_, task) in timeoutTasks {
            task.cancel()
        }
        timeoutTasks.removeAll()

        for (_, handler) in pendingCommands {
            handler(.failure(ViewerRelayClientError.notConnected))
        }
        pendingCommands.removeAll()
    }
}
