import ClaudeSpyEncryption
import Foundation

// MARK: - WebSocket Message

/// All message types that can be sent over the WebSocket connection between
/// Host, External Server, and Viewer clients.
public enum WebSocketMessage: Codable, Sendable {
    // MARK: - Host → Server

    /// Host registers with the relay server after connecting
    case registerHost(RegisterHostMessage)

    /// Host responds to a command from viewer
    case commandResponse(CommandResponseMessage)

    /// Host sends terminal stream data (continuous updates)
    case terminalStream(TerminalStreamMessage)

    /// Host sends complete session state (on viewer connect or request)
    case sessionState(SessionStateMessage)

    // MARK: - Server → Host

    /// Server confirms host registration
    case hostRegistered(HostRegisteredMessage)

    /// Server relays a command from viewer
    case command(CommandMessage)

    /// Server notifies host that viewer has connected (includes public key for E2EE)
    case viewerConnected(ViewerConnectedMessage)

    /// Server notifies host that viewer has disconnected
    case viewerDisconnected

    /// Server notifies that this pairing has been removed (the other side unpaired)
    case unpaired

    // MARK: - Viewer → Server

    /// Viewer registers with the relay server after connecting
    case registerViewer(RegisterViewerMessage)

    // Viewer sends a command to be relayed to host
    // (Uses same `command` case as Server → Host for symmetry)

    /// Viewer requests current session state from host
    case requestSessionState

    /// Viewer sends push notification token to server (iOS only)
    case registerPushToken(RegisterPushTokenMessage)

    // MARK: - Server → Viewer

    /// Server confirms viewer registration
    case viewerRegistered(ViewerRegisteredMessage)

    /// Server confirms push token registration
    case pushTokenRegistered(PushTokenRegisteredMessage)

    /// Server notifies viewer that host has connected (includes public key for E2EE)
    case hostConnected(ViewerConnectedMessage)

    /// Server notifies viewer that host has disconnected
    case hostDisconnected

    // (sessionState, commandResponse are shared with Host → Server)

    // MARK: - Bidirectional

    /// Peer-to-peer hello exchanged end-to-end after E2EE is established.
    /// Carries each client's version info so peers can gate the session on
    /// compatibility without the relay server seeing or touching versions.
    case peerHello(PeerHelloMessage)

    /// Ping to keep connection alive
    case ping

    /// Pong response to ping
    case pong

    /// Error message
    case error(ErrorMessage)

    // MARK: - End-to-End Encrypted

    /// An encrypted message that the server cannot decrypt.
    /// Contains the encrypted payload and metadata about the inner message type.
    case encrypted(EncryptedWebSocketMessage)

    // MARK: - Encrypted Push Notifications

    /// Host sends encrypted push notification payload to be relayed via APNs.
    /// Server forwards to APNs with generic placeholder text; iOS extension decrypts.
    case encryptedPush(EncryptedPushPayload)

    // MARK: - Plugin system (agent-blind)

    /// Host pushes a per-session state update (high-frequency). Carries the
    /// `AgentState`, including the open response form.
    case agentSessionStatus(AgentSessionStatusMessage)

    /// Viewer submits a structured response for a previously-emitted request.
    case agentResponseSubmission(AgentResponseSubmissionMessage)

    /// Host pushes the complete enabled-plugin presentation set (on connect and
    /// on enable/disable/upgrade).
    case pluginPresentations(PluginPresentationsMessage)

    /// Host pushes a pre-baked notification over the live WebSocket so a
    /// backgrounded-but-connected viewer can show a local notification (the
    /// parallel APNs `.encryptedPush` is dropped by the relay while connected).
    case agentNotification(AgentNotificationMessage)
}

// MARK: - Encrypted Message Wrapper

/// Wraps an encrypted payload for WebSocket transmission.
/// The server passes this through without decryption.
/// The actual message type is only known after decryption.
public struct EncryptedWebSocketMessage: Codable, Sendable {
    /// The encrypted payload (ciphertext + sender key ID + version)
    public let payload: EncryptedPayload

    public init(payload: EncryptedPayload) {
        self.payload = payload
    }
}

// MARK: - Error Message

/// Error information sent over WebSocket
public struct ErrorMessage: Codable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool

    public init(code: String, message: String, recoverable: Bool = true) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
    }

    /// Error code sent by the server when a pair ID is no longer valid.
    public static let invalidPairCode = "INVALID_PAIR"

    public static func invalidPair() -> ErrorMessage {
        ErrorMessage(code: invalidPairCode, message: "Pair ID is invalid or expired", recoverable: false)
    }

    public static func notConnected(_ device: String) -> ErrorMessage {
        ErrorMessage(code: "NOT_CONNECTED", message: "\(device) is not connected")
    }

    public static func commandFailed(_ reason: String) -> ErrorMessage {
        ErrorMessage(code: "COMMAND_FAILED", message: reason)
    }
}

// MARK: - Codable Implementation

public extension WebSocketMessage {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case registerHost
        case commandResponse
        case terminalStream
        case sessionState
        case hostRegistered
        case command
        case viewerConnected
        case viewerDisconnected
        case registerViewer
        case requestSessionState
        case registerPushToken
        case viewerRegistered
        case pushTokenRegistered
        case hostConnected
        case hostDisconnected
        case unpaired
        case peerHello
        case ping
        case pong
        case error
        case encrypted
        case encryptedPush
        case agentSessionStatus
        case agentResponseSubmission
        case pluginPresentations
        case agentNotification
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .registerHost:
            let payload = try container.decode(RegisterHostMessage.self, forKey: .payload)
            self = .registerHost(payload)
        case .commandResponse:
            let payload = try container.decode(CommandResponseMessage.self, forKey: .payload)
            self = .commandResponse(payload)
        case .terminalStream:
            let payload = try container.decode(TerminalStreamMessage.self, forKey: .payload)
            self = .terminalStream(payload)
        case .sessionState:
            let payload = try container.decode(SessionStateMessage.self, forKey: .payload)
            self = .sessionState(payload)
        case .hostRegistered:
            let payload = try container.decode(HostRegisteredMessage.self, forKey: .payload)
            self = .hostRegistered(payload)
        case .command:
            let payload = try container.decode(CommandMessage.self, forKey: .payload)
            self = .command(payload)
        case .viewerConnected:
            let payload = try container.decode(ViewerConnectedMessage.self, forKey: .payload)
            self = .viewerConnected(payload)
        case .viewerDisconnected:
            self = .viewerDisconnected
        case .registerViewer:
            let payload = try container.decode(RegisterViewerMessage.self, forKey: .payload)
            self = .registerViewer(payload)
        case .requestSessionState:
            self = .requestSessionState
        case .registerPushToken:
            let payload = try container.decode(RegisterPushTokenMessage.self, forKey: .payload)
            self = .registerPushToken(payload)
        case .viewerRegistered:
            let payload = try container.decode(ViewerRegisteredMessage.self, forKey: .payload)
            self = .viewerRegistered(payload)
        case .pushTokenRegistered:
            let payload = try container.decode(PushTokenRegisteredMessage.self, forKey: .payload)
            self = .pushTokenRegistered(payload)
        case .hostConnected:
            let payload = try container.decode(ViewerConnectedMessage.self, forKey: .payload)
            self = .hostConnected(payload)
        case .hostDisconnected:
            self = .hostDisconnected
        case .unpaired:
            self = .unpaired
        case .peerHello:
            let payload = try container.decode(PeerHelloMessage.self, forKey: .payload)
            self = .peerHello(payload)
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        case .error:
            let payload = try container.decode(ErrorMessage.self, forKey: .payload)
            self = .error(payload)
        case .encrypted:
            let payload = try container.decode(EncryptedWebSocketMessage.self, forKey: .payload)
            self = .encrypted(payload)
        case .encryptedPush:
            let payload = try container.decode(EncryptedPushPayload.self, forKey: .payload)
            self = .encryptedPush(payload)
        case .agentSessionStatus:
            let payload = try container.decode(AgentSessionStatusMessage.self, forKey: .payload)
            self = .agentSessionStatus(payload)
        case .agentResponseSubmission:
            let payload = try container.decode(AgentResponseSubmissionMessage.self, forKey: .payload)
            self = .agentResponseSubmission(payload)
        case .pluginPresentations:
            let payload = try container.decode(PluginPresentationsMessage.self, forKey: .payload)
            self = .pluginPresentations(payload)
        case .agentNotification:
            let payload = try container.decode(AgentNotificationMessage.self, forKey: .payload)
            self = .agentNotification(payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .registerHost(payload):
            try container.encode(MessageType.registerHost, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .commandResponse(payload):
            try container.encode(MessageType.commandResponse, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .terminalStream(payload):
            try container.encode(MessageType.terminalStream, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .sessionState(payload):
            try container.encode(MessageType.sessionState, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .hostRegistered(payload):
            try container.encode(MessageType.hostRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .command(payload):
            try container.encode(MessageType.command, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .viewerConnected(payload):
            try container.encode(MessageType.viewerConnected, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .viewerDisconnected:
            try container.encode(MessageType.viewerDisconnected, forKey: .type)
        case let .registerViewer(payload):
            try container.encode(MessageType.registerViewer, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .requestSessionState:
            try container.encode(MessageType.requestSessionState, forKey: .type)
        case let .registerPushToken(payload):
            try container.encode(MessageType.registerPushToken, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .viewerRegistered(payload):
            try container.encode(MessageType.viewerRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .pushTokenRegistered(payload):
            try container.encode(MessageType.pushTokenRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .hostConnected(payload):
            try container.encode(MessageType.hostConnected, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .hostDisconnected:
            try container.encode(MessageType.hostDisconnected, forKey: .type)
        case .unpaired:
            try container.encode(MessageType.unpaired, forKey: .type)
        case let .peerHello(payload):
            try container.encode(MessageType.peerHello, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .ping:
            try container.encode(MessageType.ping, forKey: .type)
        case .pong:
            try container.encode(MessageType.pong, forKey: .type)
        case let .error(payload):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .encrypted(payload):
            try container.encode(MessageType.encrypted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .encryptedPush(payload):
            try container.encode(MessageType.encryptedPush, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .agentSessionStatus(payload):
            try container.encode(MessageType.agentSessionStatus, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .agentResponseSubmission(payload):
            try container.encode(MessageType.agentResponseSubmission, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .pluginPresentations(payload):
            try container.encode(MessageType.pluginPresentations, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .agentNotification(payload):
            try container.encode(MessageType.agentNotification, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }

    /// Human-readable message type for logging
    var messageType: String {
        switch self {
        case .registerHost: MessageType.registerHost.rawValue
        case .commandResponse: MessageType.commandResponse.rawValue
        case .terminalStream: MessageType.terminalStream.rawValue
        case .sessionState: MessageType.sessionState.rawValue
        case .hostRegistered: MessageType.hostRegistered.rawValue
        case .command: MessageType.command.rawValue
        case .viewerConnected: MessageType.viewerConnected.rawValue
        case .viewerDisconnected: MessageType.viewerDisconnected.rawValue
        case .registerViewer: MessageType.registerViewer.rawValue
        case .requestSessionState: MessageType.requestSessionState.rawValue
        case .registerPushToken: MessageType.registerPushToken.rawValue
        case .viewerRegistered: MessageType.viewerRegistered.rawValue
        case .pushTokenRegistered: MessageType.pushTokenRegistered.rawValue
        case .hostConnected: MessageType.hostConnected.rawValue
        case .hostDisconnected: MessageType.hostDisconnected.rawValue
        case .unpaired: MessageType.unpaired.rawValue
        case .peerHello: MessageType.peerHello.rawValue
        case .ping: MessageType.ping.rawValue
        case .pong: MessageType.pong.rawValue
        case .error: MessageType.error.rawValue
        case .encrypted: MessageType.encrypted.rawValue
        case .encryptedPush: MessageType.encryptedPush.rawValue
        case .agentSessionStatus: MessageType.agentSessionStatus.rawValue
        case .agentResponseSubmission: MessageType.agentResponseSubmission.rawValue
        case .pluginPresentations: MessageType.pluginPresentations.rawValue
        case .agentNotification: MessageType.agentNotification.rawValue
        }
    }
}

// MARK: - Encryption Extensions

public extension WebSocketMessage {
    /// Whether this message type should be encrypted for E2EE.
    var shouldEncrypt: Bool {
        switch self {
        case .sessionState,
             .command,
             .commandResponse,
             .terminalStream,
             .peerHello,
             .agentSessionStatus,
             .agentResponseSubmission,
             .pluginPresentations,
             .agentNotification:
            true
        default:
            false
        }
    }

    #if canImport(Security)
        /// Encrypts this message using the provided E2EE service.
        /// - Parameter e2eeService: The E2EE service to use for encryption
        /// - Returns: An encrypted WebSocket message wrapper
        /// - Throws: Encryption or encoding errors
        func encrypt(using e2eeService: E2EEService) async throws -> WebSocketMessage {
            guard shouldEncrypt else {
                // Non-encryptable messages are returned as-is
                return self
            }

            // Encode the inner payload to JSON
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let innerData = try encoder.encode(self)

            // Encrypt the inner payload
            let encryptedPayload = try await e2eeService.encrypt(innerData)

            // Wrap in encrypted message (server cannot see message type)
            return .encrypted(EncryptedWebSocketMessage(payload: encryptedPayload))
        }

        /// Decrypts an encrypted message using the provided E2EE service.
        /// - Parameter e2eeService: The E2EE service to use for decryption
        /// - Returns: The decrypted WebSocket message
        /// - Throws: Decryption or decoding errors
        func decrypt(using e2eeService: E2EEService) async throws -> WebSocketMessage {
            guard case let .encrypted(encryptedMessage) = self else {
                // Non-encrypted messages are returned as-is
                return self
            }

            // Decrypt the payload
            let decryptedData = try await e2eeService.decrypt(encryptedMessage.payload)

            // Decode the inner message
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WebSocketMessage.self, from: decryptedData)
        }
    #endif
}
