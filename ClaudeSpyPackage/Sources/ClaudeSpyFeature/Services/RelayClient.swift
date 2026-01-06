import Foundation
import os
import ClaudeSpyCommon

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
        case .commandFailed(let message):
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
public final class RelayClient: Sendable {
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

    private let logger = Logger(subsystem: "com.claudespy.ios", category: "RelayClient")

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether the Mac is currently connected to the relay
    public private(set) var isMacConnected: Bool = false

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

    /// Server URL for reconnection
    private var serverURL: URL?

    /// Whether we should attempt reconnection
    private var shouldReconnect: Bool = false

    /// Current reconnection attempt
    private var reconnectionAttempt: Int = 0

    /// Maximum reconnection attempts before giving up
    private let maxReconnectionAttempts = 10

    /// Task for receiving messages
    private var receiveTask: Task<Void, Never>?

    /// Task for ping/pong keep-alive
    private var pingTask: Task<Void, Never>?

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

    // MARK: - Initialization

    public init() {}

    // MARK: - Connection Management

    /// Connect to the external relay server
    /// - Parameters:
    ///   - serverURL: WebSocket URL of the relay server
    ///   - pairId: The pair ID from device pairing
    ///   - deviceId: Unique identifier for this iOS device
    ///   - deviceName: Display name for this iOS device
    public func connect(
        serverURL: URL,
        pairId: String,
        deviceId: String,
        deviceName: String
    ) async {
        guard state != .connecting, !state.isConnected else {
            logger.warning("Already connected or connecting")
            return
        }

        self.serverURL = serverURL
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.shouldReconnect = true
        self.reconnectionAttempt = 0

        await performConnect()
    }

    /// Disconnect from the relay server
    public func disconnect() async {
        shouldReconnect = false
        await cleanupConnection()
        state = .disconnected
    }

    // MARK: - Sending Messages

    /// Send a command to be relayed to Mac (fire-and-forget)
    public func sendCommand(_ command: CommandMessage) async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot send command")
            return
        }

        let message = WebSocketMessage.command(command)
        await send(message)
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

            // Send the command
            Task {
                await send(.command(command))
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

            // Send the command
            Task {
                await send(.command(command))
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

    // MARK: - Private Methods

    private func performConnect() async {
        guard let serverURL, let pairId, let deviceId, let deviceName else {
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
            RegisterIOSMessage(pairId: pairId, deviceId: deviceId, deviceName: deviceName)
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
        switch message {
        case let .iosRegistered(response):
            if response.success {
                logger.info("Successfully registered with relay server")
                state = .connected
                connectedMacName = response.macDeviceName
                isMacConnected = response.macDeviceName != nil
                onMacConnectionChange?(isMacConnected)

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
            state = .reconnecting(attempt: reconnectionAttempt)

            // Exponential backoff: 1s, 2s, 4s, 8s, etc. up to 60s
            let delay = min(60, Int(pow(2.0, Double(reconnectionAttempt - 1))))
            logger.info("Reconnecting in \(delay) seconds (attempt \(self.reconnectionAttempt))")

            try? await Task.sleep(for: .seconds(delay))

            if shouldReconnect, !Task.isCancelled {
                await performConnect()
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
