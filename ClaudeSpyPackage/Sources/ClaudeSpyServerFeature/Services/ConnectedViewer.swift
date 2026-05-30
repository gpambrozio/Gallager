import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Dependencies
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

    @ObservationIgnored
    @Dependency(PushNotificationLogService.self) private var pushNotificationLog

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

    /// Structured version-mismatch result, set when the viewer's peerHello fails
    /// compatibility and cleared on the next connection attempt. The human-readable
    /// text is still carried on the `.error` state; this property lets the UI
    /// render update-required affordances without string parsing.
    public private(set) var versionMismatch: VersionCompatibility.VersionMismatch?

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

    /// Task for retrying registration if the first attempt is dropped
    private var registrationRetryTask: Task<Void, Never>?

    /// Serial chain for fire-and-forget commands (keystrokes, raw input).
    /// Each new command awaits the previous one to preserve WebSocket ordering.
    private var pendingFireAndForget: Task<Void, Never>?

    /// Serial chain for outbound encrypted messages. Encrypted sends have multiple
    /// suspension points (E2EE check, encrypt, WebSocket send), so concurrent
    /// callers can interleave and reorder messages on the wire. Chaining each
    /// send on the previous one guarantees viewers receive messages in the same
    /// order the host enqueued them — critical for hook events vs. session state
    /// pushes, which would otherwise race and leave `claudeSession` wiped on the
    /// viewer.
    private var pendingSend: Task<Void, Never>?

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

    /// Called when the partner's device name is received (for persisting to settings).
    /// Fires whenever the relay reports a (possibly updated) viewer device name —
    /// e.g. on `HostRegisteredMessage.viewerDeviceName` or `ViewerConnectedMessage.deviceName`.
    public var onPartnerDeviceNameReceived: (@MainActor @Sendable (String) async -> Void)?

    /// Called when the server notifies that this pairing was removed by the other side
    public var onUnpaired: (@MainActor @Sendable () async -> Void)?

    /// Provides the current pending-attention session count, used as the badge
    /// value on outgoing push notifications so the iOS app icon badge stays in
    /// sync with the host's needs-attention count.
    public var onPendingSessionCount: (@MainActor @Sendable () async -> Int)?

    /// Called when this viewer submits a plugin response (iOS→Mac). The
    /// coordinator routes it to the owning plugin core's `deliverResponse`.
    /// Mirrors how `onCommand` routes inbound viewer messages up to the manager.
    public var onAgentResponseSubmission: (@Sendable (AgentResponseSubmissionMessage) async -> Void)?

    /// Called once the viewer becomes fully connected (E2EE up + peerHello
    /// validated), the same point session-state pushes become valid. The manager
    /// uses this to push the current plugin presentations on connect (spec §7.2).
    public var onViewerConnected: (@MainActor @Sendable () async -> Void)?

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
        versionMismatch = nil

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

    /// Re-enable reconnection after a terminal failure (e.g. version mismatch) and
    /// immediately attempt to reconnect.
    ///
    /// `handleVersionMismatch` sets `shouldReconnect = false` so the host stops
    /// retrying a broken handshake. E2E scenarios that "upgrade" the host and
    /// expect the connection to recover call this to flip the flag back on and
    /// kick a fresh `performConnect`.
    public func enableReconnectAndRetry() async {
        shouldReconnect = true
        reconnectionDelayTask?.cancel()
        reconnectionDelayTask = nil
        reconnectionAttempt = 0
        versionMismatch = nil

        guard !state.isConnected, state != .connecting else {
            return
        }

        logger.info("Re-enabling reconnection and retrying for viewer: \(viewerName)")
        await performConnect()
    }

    // MARK: - Sending Messages

    /// Send a high-frequency per-session working/attention badge update to this
    /// viewer (encrypted, spec §7.2).
    public func sendAgentSessionStatus(
        sessionId: String,
        pluginId: String,
        working: Bool,
        attention: Bool
    ) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send agent session status")
            return
        }
        let message = WebSocketMessage.agentSessionStatus(
            AgentSessionStatusMessage(
                pairId: id,
                sessionId: sessionId,
                pluginId: pluginId,
                working: working,
                attention: attention,
                timestamp: Date()
            )
        )
        await sendEncrypted(message)
    }

    /// Send an encrypted push notification with arbitrary title/body to this
    /// viewer. Used by `notification.create --push` so CLI-triggered alerts
    /// follow the same APNs path as Claude hook events.
    public func sendCustomPushNotification(
        title: String,
        body: String,
        paneId: String?
    ) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send custom push")
            return
        }

        guard await e2eeService.isSessionEstablished else {
            logger.error("E2EE session not established, cannot send custom push")
            return
        }

        let content = NotificationContent(
            title: title,
            body: body,
            eventType: "cli.notify",
            pairId: id,
            paneId: paneId,
            timestamp: Date()
        )

        do {
            let encryptedContent = try await e2eeService.encrypt(content)
            let badge = await onPendingSessionCount?()
            let payload = EncryptedPushPayload(
                encryptedContent: encryptedContent,
                pairId: id,
                badge: badge,
                silent: false
            )
            await send(.encryptedPush(payload))
            // Log the (pre-formatted, agent-blind) notification title so E2E
            // scenarios can tell notification kinds apart — the wire `eventType`
            // stays "cli.notify" for the NSE; this is a test-only signal.
            pushNotificationLog.logPushSent(title, paneId)
        } catch {
            logger.error("Failed to encrypt custom push notification: \(error)")
        }
    }

    /// Send a silent (background) APNs push that only updates the iOS app
    /// badge — no alert, no sound, no Notification Service Extension. Used when
    /// the host clears a session from the "needs attention" state so the iOS
    /// badge tracks the new lower count.
    public func sendBadgeUpdate(badge: Int) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send badge update")
            return
        }

        guard await e2eeService.isSessionEstablished else {
            logger.error("E2EE session not established, cannot send badge update")
            return
        }

        // Encrypt a placeholder content so the wire shape matches event pushes.
        // The Notification Service Extension never runs for silent pushes, so
        // the receiver only consumes the unencrypted `badge` field.
        let content = NotificationContent(
            title: "",
            body: "",
            eventType: "badge.update",
            pairId: id,
            paneId: nil,
            timestamp: Date()
        )

        do {
            let encryptedContent = try await e2eeService.encrypt(content)
            let payload = EncryptedPushPayload(
                encryptedContent: encryptedContent,
                pairId: id,
                badge: badge,
                silent: true
            )
            await send(.encryptedPush(payload))
            pushNotificationLog.logPushSent("badge.update", nil)
        } catch {
            logger.error("Failed to encrypt badge update: \(error)")
        }
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

    /// Send this host's peerHello to the viewer once the E2EE session is up.
    /// Called right after establishing E2EE on `.viewerConnected`.
    private func sendPeerHello() async {
        let hello = PeerHelloMessage(
            appVersion: VersionCompatibility.currentAppVersion,
            minRequiredPartnerVersion: VersionCompatibility.minRequiredViewerVersion
        )
        logger.info(
            "Sending peerHello to viewer",
            metadata: [
                "appVersion": "\(hello.appVersion)",
                "minRequiredPartnerVersion": "\(hello.minRequiredPartnerVersion)",
            ]
        )
        await sendEncrypted(.peerHello(hello))
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

        let sessionState = await onSessionStateRequest().withPairId(id)
        logger.info("Pushing session state to viewer: \(viewerName)")
        await sendEncrypted(.sessionState(sessionState))
    }

    /// Open or retract an iOS response form for a plugin (encrypted). A non-nil
    /// `request` opens the form; `request == nil` retracts the open form with
    /// `requestId`. Mirrors `sendHookEvent`/`pushSessionState`: E2EE, ordered on
    /// the same serial send chain.
    public func sendAgentResponseRequest(
        sessionId: String,
        pluginId: String,
        requestId: String,
        request: AgentResponseRequest?
    ) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send agent response request")
            return
        }

        let message = WebSocketMessage.agentResponseRequest(
            AgentResponseRequestMessage(
                pairId: id,
                sessionId: sessionId,
                pluginId: pluginId,
                requestId: requestId,
                request: request
            )
        )
        await sendEncrypted(message)
    }

    /// Push the complete enabled-plugin presentation set to this viewer
    /// (encrypted). Sent on viewer connect and on enable/disable; always the
    /// complete set (spec §7.2/§7.3).
    public func sendPluginPresentations(_ presentations: [PluginPresentation]) async {
        guard state.isConnected else {
            logger.debug("Not connected to \(viewerName), cannot send plugin presentations")
            return
        }

        let message = WebSocketMessage.pluginPresentations(
            PluginPresentationsMessage(pairId: id, presentations: presentations)
        )
        await sendEncrypted(message)
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

        // Retry registration if the server's async WebSocket handler wasn't ready.
        // On localhost, the client can send registerHost before the server's
        // onUpgrade Task is scheduled, causing the frame to be silently dropped.
        registrationRetryTask = Task { [weak self] in
            for attempt in 1...3 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let self, self.state == .connecting else { return }
                self.logger.info("Registration not confirmed, resending registerHost (attempt \(attempt))")
                await self.send(registerMessage)
            }
        }

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
            registrationRetryTask?.cancel()
            registrationRetryTask = nil

            if response.success {
                logger.info("Successfully registered with relay server for viewer: \(viewerName)")

                reconnectionAttempt = 0
                await updateState(.connected)
                connectedViewerDeviceName = response.viewerDeviceName

                // Persist the viewer name to settings so the UI shows the user's
                // chosen device name instead of the placeholder from initial pairing.
                if let viewerDeviceName = response.viewerDeviceName {
                    await onPartnerDeviceNameReceived?(viewerDeviceName)
                }
                // `isViewerConnected` is deliberately NOT set here — it's flipped to
                // true only after the viewer's peerHello arrives and passes the
                // compatibility check. Setting it eagerly would surface the peer as
                // "Connected" in the UI during the handshake window, before we know
                // whether versions are compatible.

                // Establish E2EE session if viewer is connected and we have their public key.
                // The relay also fires `.viewerConnected` in this case, which re-establishes
                // E2EE and drives the peerHello handshake.
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
            if let onCommand {
                if command.command.requiresResponse {
                    if let response = await onCommand(command) {
                        await sendEncrypted(.commandResponse(response))
                    }
                } else {
                    // Fire-and-forget: chain on the previous task so commands
                    // execute in the order they arrive on the WebSocket.
                    // Without this, concurrent unstructured Tasks can reach the
                    // TmuxCommandExecutor actor out of order, reordering keystrokes.
                    let handler = onCommand
                    let previous = pendingFireAndForget
                    pendingFireAndForget = Task {
                        _ = await previous?.value
                        _ = await handler(command)
                    }
                }
            }

        case let .agentResponseSubmission(submission):
            logger.info(
                "Received plugin response submission from viewer",
                metadata: ["pluginId": "\(submission.pluginId)", "requestId": "\(submission.requestId)"]
            )
            await onAgentResponseSubmission?(submission)

        case let .viewerConnected(connectedMessage):
            logger.info("Viewer device connected")

            // Persist the viewer name to settings if the relay included one,
            // so a renamed iOS device propagates to the macOS UI.
            if let deviceName = connectedMessage.deviceName {
                connectedViewerDeviceName = deviceName
                await onPartnerDeviceNameReceived?(deviceName)
            }

            // `isViewerConnected` stays false until peerHello validation succeeds —
            // see `.peerHello` below. Keeping the flag off during the handshake
            // window prevents the UI from flashing "Connected" on mismatch.

            // Establish E2EE, then send peerHello. The viewer will reply with its own
            // peerHello; both sides validate versions peer-to-peer and disconnect on
            // mismatch. Session state is pushed when the viewer requests it after
            // completing its own peerHello validation.
            if
                await establishE2EEWithPartner(
                    publicKey: connectedMessage.publicKey,
                    keyId: connectedMessage.publicKeyId
                ) {
                await sendPeerHello()
            }

        case let .peerHello(peerHello):
            logger.info(
                "Received peerHello from viewer",
                metadata: ["appVersion": "\(peerHello.appVersion)"]
            )
            if
                let mismatch = VersionCompatibility.checkCompatibility(
                    partnerAppVersion: peerHello.appVersion,
                    partnerMinRequiredOurVersion: peerHello.minRequiredPartnerVersion,
                    partnerRole: .viewer
                ) {
                await handleVersionMismatch(mismatch)
            } else {
                // Compatible — now safe to surface the viewer as connected; the
                // session-state push will fire when the viewer requests it.
                isViewerConnected = true
                // Push the current plugin presentations now that the viewer is
                // ready to receive (the session-state push is still pull-based).
                await onViewerConnected?()
            }

        case .viewerDisconnected:
            logger.info("Viewer device disconnected")
            isViewerConnected = false
            connectedViewerDeviceName = nil

        case .unpaired:
            logger.info("Pairing removed by the other side")
            shouldReconnect = false
            await cleanupConnection()
            await updateState(.disconnected)
            await onUnpaired?()

        case .requestSessionState:
            logger.info("Viewer requested session state")
            await pushSessionState()

        case .ping:
            await send(.pong)

        case .pong:
            break

        case let .error(errorMessage):
            if errorMessage.code == ErrorMessage.invalidPairCode {
                logger.info("Received INVALID_PAIR error, treating as unpair")
                shouldReconnect = false
                await cleanupConnection()
                await updateState(.disconnected)
                await onUnpaired?()
            } else {
                logger.error("Server error: \(errorMessage.message)")
                if !errorMessage.recoverable {
                    await updateState(.error(errorMessage.message))
                    await disconnect()
                }
            }

        default:
            logger.debug("Received unhandled message type")
        }
    }

    // MARK: - Version Compatibility

    /// Handles a detected version mismatch by stopping reconnects and surfacing an error.
    /// The mismatch itself is computed by `VersionCompatibility.checkCompatibility`;
    /// only the user-facing messaging and state transition are host-specific.
    private func handleVersionMismatch(_ mismatch: VersionCompatibility.VersionMismatch) async {
        let message: String
        switch mismatch {
        case let .weAreTooOld(required):
            message = "This Mac app is out of date. Viewer \(viewerName) requires version \(required) or later. Please update."
        case let .partnerTooOld(partnerVersion):
            let versionText = partnerVersion.isEmpty ? "an older version" : "version \(partnerVersion)"
            message = "Viewer \(viewerName) is running \(versionText) and cannot connect. Please update the viewer app."
        }

        logger.error("Version mismatch with viewer \(viewerName): \(message)")
        shouldReconnect = false
        versionMismatch = mismatch
        await cleanupConnection()
        await updateState(.error(message))
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
        let previous = pendingSend
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.performEncryptedSend(message)
        }
        pendingSend = task
        await task.value
    }

    private func performEncryptedSend(_ message: WebSocketMessage) async {
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

        registrationRetryTask?.cancel()
        registrationRetryTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        urlSession?.invalidateAndCancel()
        urlSession = nil

        // Drop the serial chain heads so a reconnect starts a fresh chain
        // instead of waiting on stale in-flight encrypt tasks from the old
        // socket. The trailing tasks aren't cancelled (they don't check
        // `isCancelled`); they just finish as no-ops since `webSocketTask`
        // is now nil.
        pendingFireAndForget = nil
        pendingSend = nil
    }

    private func updateState(_ newState: ConnectionState) async {
        state = newState
        if let onConnectionStateChange {
            await onConnectionStateChange(newState)
        }
    }
}
