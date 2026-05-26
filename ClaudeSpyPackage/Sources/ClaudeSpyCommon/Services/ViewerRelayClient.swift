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
/// This is the shared implementation used by both macOS and iOS
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

    /// Structured version-mismatch result, set when the host's peerHello fails
    /// compatibility and cleared on the next connection attempt. The human-readable
    /// text is still carried on the `.error` state; this property lets UI render
    /// update-required affordances without string parsing.
    public private(set) var versionMismatch: VersionCompatibility.VersionMismatch?

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

    /// Maximum backoff delay in seconds
    private let maxBackoffDelay = 60

    /// Task for receiving messages
    private var receiveTask: Task<Void, Never>?

    /// Task for ping/pong keep-alive
    private var pingTask: Task<Void, Never>?

    /// Task for delayed reconnection (exponential backoff)
    private var reconnectionTask: Task<Void, Never>?

    /// Task for retrying registration (handles server-side race condition)
    private var registrationRetryTask: Task<Void, Never>?

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

    /// Called when session state is received from host
    public var onSessionState: (@Sendable (SessionStateMessage) -> Void)?

    /// Called when an `agent_session_status` push arrives from the host.
    /// Carries per-session working / attention flags from a plugin sidecar.
    public var onAgentSessionStatus: (@Sendable (AgentSessionStatusUpdate) -> Void)?

    /// Called when an `agent_response_request` push arrives from the host.
    /// The Mac uses this to ask iOS to present (or dismiss) a response form
    /// for a specific session.
    public var onAgentResponseRequest: (@Sendable (AgentResponseRequestMessage) -> Void)?

    /// Called when a `plugin_presentations` push arrives from the host. iOS
    /// caches the bundle so the sidebar can render icons and short names per
    /// session.
    public var onPluginPresentations: (@Sendable (PluginPresentationsMessage) -> Void)?

    /// Per-pane terminal stream handlers, keyed by pane ID.
    /// Multiple panes can receive stream data concurrently.
    private var terminalStreamHandlers: [String: @MainActor @Sendable (TerminalStreamMessage) -> Void] = [:]

    /// Register a terminal stream handler for a specific pane
    public func setTerminalStreamHandler(
        for paneId: String,
        handler: (@MainActor @Sendable (TerminalStreamMessage) -> Void)?
    ) {
        if let handler {
            terminalStreamHandlers[paneId] = handler
        } else {
            terminalStreamHandlers.removeValue(forKey: paneId)
        }
    }

    /// Called when partner's public key is received (for persisting to settings)
    public var onPartnerKeyReceived: (@MainActor @Sendable (String, String) async -> Void)?

    /// Called when the host device disconnects (but pairing is still active)
    public var onHostDisconnected: (@MainActor @Sendable () async -> Void)?

    /// Called when the server notifies that this pairing was removed by the other side
    public var onUnpaired: (@MainActor @Sendable () async -> Void)?

    // MARK: - Initialization

    public init() { }

    private func setState(_ newState: ConnectionState) {
        state = newState
        logger.info("Connection state: \(newState)")
    }

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
        versionMismatch = nil

        // Establish E2EE session if we have partner's public key from pairing
        if let partnerKey = partnerPublicKey, let partnerKeyId = partnerPublicKeyId {
            guard let keyData = Data(base64Encoded: partnerKey) else {
                let errorMessage = "Failed to decode partner public key - encryption setup failed"
                logger.error("\(errorMessage)")
                setState(.error(errorMessage))
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
                setState(.error(errorMessage))
                return
            }
        }

        await performConnect()
    }

    /// Disconnect from the relay server
    public func disconnect() async {
        shouldReconnect = false
        await cleanupConnection()
        setState(.disconnected)
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

    /// Re-enable reconnection after a terminal failure (e.g. version mismatch) and
    /// immediately attempt to reconnect.
    ///
    /// `handleVersionMismatch` sets `shouldReconnect = false` so the client stops
    /// retrying a broken handshake. E2E scenarios that "upgrade" the peer and then
    /// expect the connection to recover call this to flip the flag back on and
    /// trigger a fresh `performConnect`.
    public func enableReconnectAndRetry() async {
        shouldReconnect = true
        reconnectionTask?.cancel()
        reconnectionTask = nil
        reconnectionAttempt = 0
        versionMismatch = nil

        guard !state.isConnected, state != .connecting else {
            logger.debug("Already connected or connecting, ignoring enableReconnectAndRetry()")
            return
        }

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

        // Fire-and-forget: just write to the WebSocket and return a synthetic success.
        // The command type declares it doesn't need a response, so no handler or timeout.
        guard command.commandType.requiresResponse else {
            await sendEncrypted(.command(commandMessage))
            // All fire-and-forget commands currently use CommandResponseMessage as Response
            if let response = CommandResponseMessage.success(for: commandMessage.id) as? C.Response {
                return .success(response)
            }
            return .failure(ViewerRelayClientError.commandFailed("Unexpected response type"))
        }

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

    /// Send a `CommandType` to the host, discarding the typed response.
    ///
    /// This is a convenience wrapper around `sendCommand(_:paneId:)` that dispatches
    /// the enum variant to the underlying generic method. Useful when the caller doesn't
    /// need the response (fire-and-forget style).
    @discardableResult
    public func send(_ command: CommandType, paneId: String) async -> Bool {
        switch command {
        case let .sendKeystroke(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .cancelOperation(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .startTerminalStream(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .stopTerminalStream(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .createTmuxSession(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .resizeTmuxPane(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .setYoloMode(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .markHandled(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .setSessionDescription(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .setSessionColor(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .setSessionEmoji(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .setWindowName(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .moveTmuxWindows(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .splitTmuxPane(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .selectTmuxPane(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .selectTmuxWindow(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .createTmuxWindow(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .submitEditorContent(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .cancelEditorSession(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .sendRawInput(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
        case let .checkRunningProcesses(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .killTmuxWindow(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .killTmuxSession(spec):
            return (try? await sendCommand(spec, paneId: "").get()) != nil
        case let .sendDroppedFiles(spec):
            return (try? await sendCommand(spec, paneId: paneId).get()) != nil
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

    /// Send this viewer's peerHello to the host once the E2EE session is up.
    /// Called right after establishing E2EE on `.hostConnected`.
    private func sendPeerHello() async {
        let hello = PeerHelloMessage(
            appVersion: VersionCompatibility.currentAppVersion,
            minRequiredPartnerVersion: VersionCompatibility.minRequiredHostVersion
        )
        logger.info(
            "Sending peerHello to host",
            metadata: [
                "appVersion": "\(hello.appVersion)",
                "minRequiredPartnerVersion": "\(hello.minRequiredPartnerVersion)",
            ]
        )
        await sendEncrypted(.peerHello(hello))
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

    /// Sends an `agent_response_submission` envelope to the host. iOS calls this
    /// when the user fills in (or dismisses) a form raised by a prior
    /// `agent_response_request`. The host hands the payload off to the plugin
    /// sidecar identified by `pluginId`, which translates it into the host
    /// agent's expected response (keystrokes, JSON-RPC, etc.).
    ///
    /// Encrypted via the established E2EE session like every other sensitive
    /// payload; no-op if the session isn't up yet (logged inside
    /// `sendEncrypted`).
    public func sendAgentResponseSubmission(_ submission: AgentResponseSubmission) async {
        guard state.isConnected else {
            logger.debug("Not connected, cannot send agent response submission")
            return
        }

        logger.info(
            "Sending agent_response_submission to host",
            metadata: [
                "pluginId": "\(submission.pluginId)",
                "sessionId": "\(submission.sessionId)",
                "requestId": "\(submission.requestId)",
            ]
        )
        await sendEncrypted(.agentResponseSubmission(submission))
    }

    // MARK: - Private Methods

    private func performConnect() async {
        guard
            let serverURL, let pairId, let deviceId, let deviceName,
            let publicKey, let publicKeyId
        else {
            logger.error("Missing connection parameters")
            setState(.error("Missing connection parameters"))
            return
        }

        setState(.connecting)

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
            setState(.error("Invalid server URL"))
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

        // Transition to connected immediately. The server's viewerRegistered
        // response may be lost due to a race condition in Vapor's WebSocket
        // upgrade: the onUpgrade Task may not have set up onText handlers
        // before the client's registration frame arrives, causing it to be
        // silently consumed by the default no-op handler. We retry below
        // to handle this.
        setState(.connected)
        reconnectionAttempt = 0

        // Retry registration after a delay to handle server-side race condition.
        // Vapor calls onUpgrade from a Swift Concurrency Task, not directly on
        // the NIO event loop. On localhost, the client's registration frame can
        // arrive before that Task runs and sets up the onText handler. The server
        // handles duplicate registrations idempotently.
        registrationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.logger.debug("Retrying registration (race condition mitigation)")
            await self?.send(registerMessage)
        }

        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    private func receiveMessages() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else {
                break
            }

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

                setState(.connected)
                connectedHostName = response.hostDeviceName
                // `isHostConnected` is deliberately NOT set here — a mismatched host
                // would otherwise surface as "Connected" in the UI until peerHello
                // validation completes and flips state to `.error`. The flag is
                // raised only after a compatible peerHello arrives (below).

                // Establish E2EE session if host is connected and we have their public key.
                // The relay also fires `.hostConnected` in this case, which re-establishes
                // E2EE and drives the peerHello handshake — so we leave the handshake and
                // session state request to that path.
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
            } else {
                logger.error("Registration failed: \(response.error ?? "Unknown error")")
                setState(.error(response.error ?? "Registration failed"))
                await disconnect()
            }

        case .hookEvent:
            // Legacy peer still sending hook events; ignore. The plugin
            // protocol replaced this with `agent_session_status` and
            // `agent_response_request`; both peers are gated to v1.33 so
            // a hook event here is from an older snapshot still in flight.
            logger.debug("Ignoring legacy hookEvent from peer")

        case let .sessionState(sessionState):
            logger.info("Received session state from host")
            onSessionState?(sessionState)

        case let .agentSessionStatus(update):
            logger.debug("Received agent_session_status from host: \(update.pluginId)/\(update.sessionId)")
            onAgentSessionStatus?(update)

        case let .agentResponseRequest(request):
            logger.info(
                "Received agent_response_request from host",
                metadata: [
                    "pluginId": "\(request.pluginId)",
                    "sessionId": "\(request.sessionId)",
                    "requestId": "\(request.requestId)",
                    "dismiss": "\(request.request == nil)",
                ]
            )
            onAgentResponseRequest?(request)

        case let .pluginPresentations(presentations):
            logger.info("Received plugin_presentations from host: \(presentations.presentations.count) plugins")
            onPluginPresentations?(presentations)

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
            terminalStreamHandlers[streamMessage.paneId]?(streamMessage)

        case let .hostConnected(connectedMessage):
            logger.info("Host device connected")

            // `isHostConnected` is NOT flipped to true here — it is set only after
            // the host's peerHello arrives and passes the compatibility check.
            // Otherwise the UI would flash "Connected" before the handshake resolves
            // on a version mismatch.

            // Establish E2EE, then send our peerHello. Session state is requested only
            // after the host's peerHello arrives and passes the compatibility check;
            // that happens in the `.peerHello` case below.
            let hostPublicKey = connectedMessage.publicKey
            let hostPublicKeyId = connectedMessage.publicKeyId
            var e2eeReady = false
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
                    e2eeReady = true
                    logger.info("E2EE session established with host on connect notification")

                    if let onPartnerKeyReceived {
                        await onPartnerKeyReceived(hostPublicKey, hostPublicKeyId)
                    }
                } catch {
                    logger.error("Failed to establish E2EE session: \(error)")
                }
            }
            if e2eeReady {
                await sendPeerHello()
            }

        case let .peerHello(peerHello):
            logger.info(
                "Received peerHello from host",
                metadata: ["appVersion": "\(peerHello.appVersion)"]
            )
            if
                let mismatch = VersionCompatibility.checkCompatibility(
                    partnerAppVersion: peerHello.appVersion,
                    partnerMinRequiredOurVersion: peerHello.minRequiredPartnerVersion,
                    partnerRole: .host
                ) {
                await handleVersionMismatch(mismatch)
                return
            }
            // Compatible — now safe to surface the host as connected and ask for state.
            isHostConnected = true
            await requestSessionState()

        case .hostDisconnected:
            logger.info("Host device disconnected")
            isHostConnected = false
            connectedHostName = nil
            await onHostDisconnected?()

        case .unpaired:
            logger.info("Pairing removed by the other side")
            shouldReconnect = false
            await cleanupConnection()
            setState(.disconnected)
            await onUnpaired?()

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
            if errorMessage.code == ErrorMessage.invalidPairCode {
                logger.info("Received INVALID_PAIR error, treating as unpair")
                shouldReconnect = false
                await cleanupConnection()
                setState(.disconnected)
                await onUnpaired?()
            } else {
                logger.error("Server error: \(errorMessage.message)")
                if !errorMessage.recoverable {
                    setState(.error(errorMessage.message))
                    await disconnect()
                }
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

    // MARK: - Version Compatibility

    /// Handles a detected version mismatch by stopping reconnects and surfacing an error.
    /// The mismatch itself is computed by `VersionCompatibility.checkCompatibility`;
    /// only the user-facing messaging and state transition are viewer-specific.
    private func handleVersionMismatch(_ mismatch: VersionCompatibility.VersionMismatch) async {
        let hostLabel = connectedHostName ?? "the host"
        let message: String
        switch mismatch {
        case let .weAreTooOld(required):
            message = "This app is out of date. \(hostLabel) requires version \(required) or later. Please update."
        case let .partnerTooOld(partnerVersion):
            let versionText = partnerVersion.isEmpty ? "an older version" : "version \(partnerVersion)"
            message = "\(hostLabel) is running \(versionText) and cannot connect. Ask the host to update."
        }

        logger.error("Version mismatch with host: \(message)")
        shouldReconnect = false
        versionMismatch = mismatch
        await cleanupConnection()
        setState(.error(message))
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
        await onHostDisconnected?()

        await cleanupConnection()

        guard shouldReconnect else { return }

        reconnectionAttempt += 1
        // Exponential backoff: 1s, 2s, 4s, 8s, ... capped at maxBackoffDelay
        let exponent = min(reconnectionAttempt - 1, 20)
        let delay = min(maxBackoffDelay, Int(pow(2, Double(exponent))))
        setState(.reconnecting(attempt: reconnectionAttempt))
        if reconnectionAttempt <= 10 {
            logger.info("Reconnecting in \(delay) seconds (attempt \(reconnectionAttempt))")
        } else {
            logger.debug("Reconnecting in \(delay) seconds (attempt \(reconnectionAttempt))")
        }

        reconnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard self.shouldReconnect else { return }

            await self.performConnect()
        }
    }

    private func cleanupConnection() async {
        receiveTask?.cancel()
        receiveTask = nil

        pingTask?.cancel()
        pingTask = nil

        reconnectionTask?.cancel()
        reconnectionTask = nil

        registrationRetryTask?.cancel()
        registrationRetryTask = nil

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
