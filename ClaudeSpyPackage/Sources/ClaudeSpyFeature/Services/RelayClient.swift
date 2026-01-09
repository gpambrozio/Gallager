import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation
import os

/// Errors that can occur during relay communication
public enum RelayClientError: Error, LocalizedError {
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

/// Client for connecting to the external relay server via WebSocket.
///
/// Handles bidirectional communication between the iOS app and the relay server,
/// receiving hook events from Mac and sending commands to Mac.
@Observable
@MainActor
final public class RelayClient {
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

    private let logger = Logger(subsystem: "com.claudespy.ios", category: "RelayClient")

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether the Mac is currently connected to the relay
    public private(set) var isMacConnected = false

    /// Name of the connected Mac device (if known)
    public private(set) var connectedMacName: String?

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

    /// Pending command continuations keyed by command ID
    private var pendingCommands: [UUID: CheckedContinuation<Result<CommandResponseMessage, Error>, Never>] = [:]

    /// Pending snapshot continuations keyed by command ID
    private var pendingSnapshots: [UUID: CheckedContinuation<Result<TerminalSnapshotMessage, Error>, Never>] = [:]

    // MARK: - Callbacks

    /// Called when a hook event is received from Mac
    public var onHookEvent: (@Sendable (HookEventMessage) -> Void)?

    /// Called when session state is received from Mac
    public var onSessionState: (@Sendable (SessionStateMessage) -> Void)?

    /// Called when a command response is received from Mac
    public var onCommandResponse: (@Sendable (CommandResponseMessage) -> Void)?

    /// Called when a terminal snapshot is received from Mac
    public var onTerminalSnapshot: (@Sendable (TerminalSnapshotMessage) -> Void)?

    /// Called when Mac connection status changes
    public var onMacConnectionChange: (@Sendable (Bool) -> Void)?

    /// Called when partner's public key is received (for persisting to settings)
    private var onPartnerKeyReceived: (@MainActor @Sendable (String, String) async -> Void)?

    // MARK: - Initialization

    public init() { }

    // MARK: - Configuration

    /// Set the handler for when partner's public key is received.
    /// Parameters are (publicKey: Base64, publicKeyId: String).
    public func setPartnerKeyHandler(
        _ handler: @escaping @MainActor @Sendable (String, String) async -> Void
    ) {
        onPartnerKeyReceived = handler
    }

    // MARK: - Connection Management

    /// Connect to the external relay server
    /// - Parameters:
    ///   - serverURL: WebSocket URL of the relay server
    ///   - pairId: The pair ID from device pairing
    ///   - deviceId: Unique identifier for this iOS device
    ///   - deviceName: Display name for this iOS device
    ///   - publicKey: Base64-encoded public key for E2EE
    ///   - publicKeyId: Unique identifier for the public key
    ///   - e2eeService: E2EE service for encrypting/decrypting messages
    ///   - partnerPublicKey: Base64-encoded public key of the Mac device (from pairing)
    ///   - partnerPublicKeyId: Unique identifier for the Mac device's public key
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
        await cleanupConnection()
        state = .disconnected
    }

    /// Reset reconnection backoff and immediately attempt to reconnect.
    ///
    /// This is useful when the app comes to foreground from background - rather than
    /// waiting for the exponential backoff timer, we reset the attempt counter and
    /// immediately try to connect.
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

        // Cancel any pending reconnection task that's waiting on backoff timer
        reconnectionTask?.cancel()
        reconnectionTask = nil

        reconnectionAttempt = 0
        await performConnect()
    }

    // MARK: - Sending Messages

    /// Send a command to be relayed to Mac (fire-and-forget, encrypted)
    public func sendCommand(_ command: CommandMessage) async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot send command")
            return
        }

        let message = WebSocketMessage.command(command)
        await sendEncrypted(message)
    }

    /// Send a command and wait for response (with Result-based completion)
    /// - Parameters:
    ///   - command: The command to send
    ///   - timeout: Maximum time to wait for response (default: 10 seconds)
    /// - Returns: Result containing CommandResponseMessage or Error
    public func sendCommandWithResponse(
        _ command: CommandMessage,
        timeout: TimeInterval = 10
    ) async -> Result<CommandResponseMessage, Error> {
        guard state.isConnected else {
            return .failure(RelayClientError.notConnected)
        }

        return await withCheckedContinuation { continuation in
            // Store continuation for this command ID
            pendingCommands[command.id] = continuation

            // Send the command (encrypted)
            Task {
                await sendEncrypted(.command(command))
            }

            // Set up timeout
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let pendingContinuation = pendingCommands.removeValue(forKey: command.id) {
                    pendingContinuation.resume(returning: .failure(RelayClientError.timeout))
                }
            }
        }
    }

    /// Send a snapshot command and wait for the snapshot data
    /// - Parameters:
    ///   - command: The capture snapshot command
    ///   - timeout: Maximum time to wait for snapshot (default: 15 seconds)
    /// - Returns: Result containing TerminalSnapshotMessage or Error
    public func sendSnapshotCommand(
        _ command: CommandMessage,
        timeout: TimeInterval = 15
    ) async -> Result<TerminalSnapshotMessage, Error> {
        guard state.isConnected else {
            return .failure(RelayClientError.notConnected)
        }

        return await withCheckedContinuation { continuation in
            // Store continuation for this command ID
            pendingSnapshots[command.id] = continuation

            // Send the command (encrypted)
            Task {
                await sendEncrypted(.command(command))
            }

            // Set up timeout
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let pendingContinuation = pendingSnapshots.removeValue(forKey: command.id) {
                    pendingContinuation.resume(returning: .failure(RelayClientError.timeout))
                }
            }
        }
    }

    /// Request current session state from Mac
    public func requestSessionState() async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot request session state")
            return
        }

        await send(.requestSessionState)
    }

    /// Send push notification token to the relay server
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
            URLQueryItem(name: "deviceType", value: "ios"),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]

        guard let wsURL = components?.url else {
            logger.error("Failed to build WebSocket URL")
            state = .error("Invalid server URL")
            return
        }

        logger.info("Connecting to relay server: \(wsURL)")

        // Create URL session
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
        let registerMessage = WebSocketMessage.registerIOS(
            RegisterIOSMessage(
                pairId: pairId,
                deviceId: deviceId,
                deviceName: deviceName,
                publicKey: publicKey,
                publicKeyId: publicKeyId
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
            guard let textData = text.data(using: .utf8) else {
                logger.error("Failed to convert message text to data")
                return
            }
            data = textData
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
                logger.debug("Decrypted message: \(decryptedMessage.messageType)")
            } catch {
                logger.error("Failed to decrypt message: \(error)")
                return
            }
        } else {
            decryptedMessage = message
        }

        switch decryptedMessage {
        case let .iosRegistered(response):
            if response.success {
                logger.info("Successfully registered with relay server")
                state = .connected
                connectedMacName = response.macDeviceName
                isMacConnected = response.macDeviceName != nil
                onMacConnectionChange?(isMacConnected)

                // Establish E2EE session if Mac is connected and we have their public key
                if
                    let macPublicKey = response.macPublicKey,
                    let macPublicKeyId = response.macPublicKeyId,
                    let keyData = Data(base64Encoded: macPublicKey),
                    let e2eeService,
                    let pairId {
                    do {
                        try await e2eeService.establishSession(
                            partnerPublicKey: keyData,
                            partnerKeyId: macPublicKeyId,
                            pairId: pairId
                        )
                        partnerPublicKey = macPublicKey
                        partnerPublicKeyId = macPublicKeyId
                        logger.info("E2EE session established with Mac")

                        // Notify app to persist partner's public key
                        if let onPartnerKeyReceived {
                            await onPartnerKeyReceived(macPublicKey, macPublicKeyId)
                        }
                    } catch {
                        logger.error("Failed to establish E2EE session: \(error)")
                    }
                }

                // Request session state if Mac is connected
                if isMacConnected {
                    await requestSessionState()
                }
            } else {
                logger.error("Registration failed: \(response.error ?? "Unknown error")")
                state = .error(response.error ?? "Registration failed")
                await disconnect()
            }

        case let .hookEvent(event):
            logger.info("Received hook event from Mac")
            onHookEvent?(event)

        case let .sessionState(sessionState):
            logger.info("Received session state from Mac")
            onSessionState?(sessionState)

        case let .commandResponse(response):
            logger.info("Received command response from Mac")
            // Resume any pending continuation for this command
            if let continuation = pendingCommands.removeValue(forKey: response.commandId) {
                if response.success {
                    continuation.resume(returning: .success(response))
                } else {
                    continuation.resume(returning: .failure(RelayClientError.commandFailed(response.error ?? "Unknown error")))
                }
            }
            // Also call the legacy callback if set
            onCommandResponse?(response)

        case let .terminalSnapshot(snapshot):
            logger.info("Received terminal snapshot from Mac")
            // Resume any pending continuation for this snapshot
            if let continuation = pendingSnapshots.removeValue(forKey: snapshot.commandId) {
                continuation.resume(returning: .success(snapshot))
            }
            // Also call the legacy callback if set
            onTerminalSnapshot?(snapshot)

        case .macConnected:
            logger.info("Mac device connected")
            isMacConnected = true
            onMacConnectionChange?(true)
            // Request session state from newly connected Mac
            await requestSessionState()

        case .macDisconnected:
            logger.info("Mac device disconnected")
            isMacConnected = false
            connectedMacName = nil
            onMacConnectionChange?(false)

        case .ping:
            await send(.pong)

        case .pong:
            // Expected response to our ping, no action needed
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
        isMacConnected = false
        connectedMacName = nil
        onMacConnectionChange?(false)

        await cleanupConnection()

        if shouldReconnect, reconnectionAttempt < maxReconnectionAttempts {
            reconnectionAttempt += 1
            let currentAttempt = reconnectionAttempt
            state = .reconnecting(attempt: currentAttempt)

            // Exponential backoff: 1s, 2s, 4s, 8s, etc. up to 60s
            let delay = min(60, Int(pow(2, Double(currentAttempt - 1))))
            logger.info("Reconnecting in \(delay) seconds (attempt \(currentAttempt))")

            // Spawn reconnection in a new task - the current task was cancelled by cleanupConnection()
            // so we need a fresh task that won't have Task.isCancelled == true
            reconnectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))

                // Only reconnect if we haven't been cancelled and still want to reconnect
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

        // Fail all pending commands with not connected error
        for (_, continuation) in pendingCommands {
            continuation.resume(returning: .failure(RelayClientError.notConnected))
        }
        pendingCommands.removeAll()

        for (_, continuation) in pendingSnapshots {
            continuation.resume(returning: .failure(RelayClientError.notConnected))
        }
        pendingSnapshots.removeAll()
    }
}
