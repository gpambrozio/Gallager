import Foundation
import Logging
import ClaudeSpyCommon

/// Client for connecting to the external relay server via WebSocket.
///
/// Handles bidirectional communication between the Mac app and the relay server,
/// forwarding hook events to iOS and receiving commands from iOS.
@Observable
@MainActor
public final class ExternalServerClient: Sendable {
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

    private let logger = Logger(label: "com.claudespy.externalserver")

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether an iOS device is currently connected to the relay
    public private(set) var isIOSConnected: Bool = false

    /// Name of the connected iOS device (if known)
    public private(set) var connectedIOSDeviceName: String?

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

    // MARK: - Callbacks

    /// Called when a command is received from iOS
    private var onCommand: (@MainActor @Sendable (CommandMessage) async -> CommandResponseMessage)?

    /// Called when session state is requested by iOS
    private var onSessionStateRequest: (@Sendable () async -> SessionStateMessage)?

    /// Called when connection state changes
    private var onConnectionStateChange: (@Sendable (ConnectionState) async -> Void)?

    // MARK: - Initialization

    public init() {}

    // MARK: - Configuration

    /// Set the handler for commands from iOS
    public func setCommandHandler(
        _ handler: @escaping @MainActor @Sendable (CommandMessage) async -> CommandResponseMessage
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

    // MARK: - Connection Management

    /// Connect to the external relay server
    /// - Parameters:
    ///   - serverURL: WebSocket URL of the relay server
    ///   - pairId: The pair ID from device pairing
    ///   - deviceId: Unique identifier for this Mac
    ///   - deviceName: Display name for this Mac
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
        await updateState(.disconnected)
    }

    // MARK: - Sending Messages

    /// Send a hook event to be relayed to iOS
    public func sendHookEvent(_ event: HookEvent) async {
        guard state.isConnected, let pairId else {
            logger.debug("Not connected, cannot send hook event")
            return
        }

        let message = WebSocketMessage.hookEvent(
            HookEventMessage(pairId: pairId, event: event)
        )
        await send(message)
    }

    /// Send session state to iOS
    public func sendSessionState(_ sessions: [String: ClaudeSession], activePanes: [String]) async {
        guard state.isConnected, let pairId else {
            logger.debug("Not connected, cannot send session state")
            return
        }

        let message = WebSocketMessage.sessionState(
            SessionStateMessage(pairId: pairId, sessions: sessions, activePanes: activePanes)
        )
        await send(message)
    }

    /// Send a terminal snapshot to iOS
    public func sendTerminalSnapshot(_ snapshot: TerminalSnapshotMessage) async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot send terminal snapshot")
            return
        }

        let message = WebSocketMessage.terminalSnapshot(snapshot)
        await send(message)
    }

    // MARK: - Private Methods

    private func performConnect() async {
        guard let serverURL, let pairId, let deviceId, let deviceName else {
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
            URLQueryItem(name: "deviceType", value: "mac"),
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
        let registerMessage = WebSocketMessage.registerMac(
            RegisterMacMessage(pairId: pairId, deviceId: deviceId, deviceName: deviceName)
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
        case let .macRegistered(response):
            if response.success {
                logger.info("Successfully registered with relay server")
                await updateState(.connected)
                connectedIOSDeviceName = response.iosDeviceName
                isIOSConnected = response.iosDeviceName != nil
            } else {
                logger.error("Registration failed: \(response.error ?? "Unknown error")")
                await updateState(.error(response.error ?? "Registration failed"))
                await disconnect()
            }

        case let .command(command):
            logger.info("Received command from iOS", metadata: ["type": "\(command.type)"])
            if let onCommand {
                logger.debug("Calling command handler")
                let response = await onCommand(command)
                logger.debug("Command handler returned, sending response")
                await send(.commandResponse(response))
                logger.debug("Command response sent")
            }

        case .iosConnected:
            logger.info("iOS device connected")
            isIOSConnected = true
            // Send current session state to newly connected iOS
            if let onSessionStateRequest {
                let state = await onSessionStateRequest()
                logger.info("Sending session state to newly connected iOS", metadata: [
                    "pairId": "\(state.pairId)",
                    "sessionCount": "\(state.sessions.count)",
                    "activePanes": "\(state.activePanes.count)"
                ])
                await send(.sessionState(state))
            } else {
                logger.warning("iOS connected but no session state handler is set!")
            }

        case .iosDisconnected:
            logger.info("iOS device disconnected")
            isIOSConnected = false
            connectedIOSDeviceName = nil

        case .requestSessionState:
            logger.info("iOS requested session state")
            if let onSessionStateRequest {
                let state = await onSessionStateRequest()
                logger.info("Sending session state", metadata: [
                    "pairId": "\(state.pairId)",
                    "sessionCount": "\(state.sessions.count)",
                    "activePanes": "\(state.activePanes.count)"
                ])
                await send(.sessionState(state))
            } else {
                logger.warning("Session state requested but no handler is set!")
            }

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
        isIOSConnected = false
        connectedIOSDeviceName = nil

        await cleanupConnection()

        if shouldReconnect, reconnectionAttempt < maxReconnectionAttempts {
            reconnectionAttempt += 1
            await updateState(.reconnecting(attempt: reconnectionAttempt))

            // Exponential backoff: 1s, 2s, 4s, 8s, etc. up to 60s
            let delay = min(60, Int(pow(2.0, Double(reconnectionAttempt - 1))))
            logger.info("Reconnecting in \(delay) seconds (attempt \(reconnectionAttempt))")

            try? await Task.sleep(for: .seconds(delay))

            if shouldReconnect, !Task.isCancelled {
                await performConnect()
            }
        } else if shouldReconnect {
            logger.error("Max reconnection attempts reached")
            await updateState(.error("Connection lost after \(maxReconnectionAttempts) attempts"))
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
