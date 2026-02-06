import ClaudeSpyEncryption
import Foundation

// MARK: - WebSocket Message

/// All message types that can be sent over the WebSocket connection between
/// Mac, External Server, and iOS clients.
public enum WebSocketMessage: Codable, Sendable {
    // MARK: - Mac → Server

    /// Mac registers with the relay server after connecting
    case registerMac(RegisterMacMessage)

    /// Mac forwards a hook event to be relayed to iOS
    case hookEvent(HookEventMessage)

    /// Mac responds to a command from iOS
    case commandResponse(CommandResponseMessage)

    /// Mac sends terminal stream data (continuous updates)
    case terminalStream(TerminalStreamMessage)

    /// Mac sends complete session state (on iOS connect or request)
    case sessionState(SessionStateMessage)

    // MARK: - Server → Mac

    /// Server confirms Mac registration
    case macRegistered(MacRegisteredMessage)

    /// Server relays a command from iOS
    case command(CommandMessage)

    /// Server notifies Mac that iOS has connected (includes public key for E2EE)
    case iosConnected(DeviceConnectedMessage)

    /// Server notifies Mac that iOS has disconnected
    case iosDisconnected

    /// Server notifies Mac that a Mac viewer has connected (includes public key for E2EE)
    case macViewerConnected(DeviceConnectedMessage)

    /// Server notifies Mac that a Mac viewer has disconnected
    case macViewerDisconnected

    // MARK: - iOS → Server

    /// iOS registers with the relay server after connecting
    case registerIOS(RegisterIOSMessage)

    // iOS sends a command to be relayed to Mac
    // (Uses same `command` case as Server → Mac for symmetry)

    /// iOS requests current session state from Mac
    case requestSessionState

    /// iOS sends push notification token to server
    case registerPushToken(RegisterPushTokenMessage)

    // MARK: - Server → iOS

    /// Server confirms iOS registration
    case iosRegistered(IOSRegisteredMessage)

    /// Server confirms push token registration
    case pushTokenRegistered(PushTokenRegisteredMessage)

    /// Server notifies iOS that Mac has connected (includes public key for E2EE)
    case macConnected(DeviceConnectedMessage)

    /// Server notifies iOS that Mac has disconnected
    case macDisconnected

    // (hookEvent, sessionState, commandResponse are shared with Mac → Server)

    // MARK: - Mac Viewer → Server

    /// Mac viewer registers with the relay server after connecting
    case registerMacViewer(RegisterMacViewerMessage)

    // MARK: - Server → Mac Viewer

    /// Server confirms Mac viewer registration
    case macViewerRegistered(MacViewerRegisteredMessage)

    // (macConnected, macDisconnected are shared with Server → iOS)

    // MARK: - Bidirectional

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

    /// Mac sends encrypted push notification payload to be relayed via APNs.
    /// Server forwards to APNs with generic placeholder text; iOS extension decrypts.
    case encryptedPush(EncryptedPushPayload)
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

    public static func invalidPair() -> ErrorMessage {
        ErrorMessage(code: "INVALID_PAIR", message: "Pair ID is invalid or expired", recoverable: false)
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
        case registerMac
        case hookEvent
        case commandResponse
        case terminalStream
        case sessionState
        case macRegistered
        case command
        case iosConnected
        case iosDisconnected
        case macViewerConnected
        case macViewerDisconnected
        case registerIOS
        case requestSessionState
        case registerPushToken
        case iosRegistered
        case pushTokenRegistered
        case macConnected
        case macDisconnected
        case registerMacViewer
        case macViewerRegistered
        case ping
        case pong
        case error
        case encrypted
        case encryptedPush
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .registerMac:
            let payload = try container.decode(RegisterMacMessage.self, forKey: .payload)
            self = .registerMac(payload)
        case .hookEvent:
            let payload = try container.decode(HookEventMessage.self, forKey: .payload)
            self = .hookEvent(payload)
        case .commandResponse:
            let payload = try container.decode(CommandResponseMessage.self, forKey: .payload)
            self = .commandResponse(payload)
        case .terminalStream:
            let payload = try container.decode(TerminalStreamMessage.self, forKey: .payload)
            self = .terminalStream(payload)
        case .sessionState:
            let payload = try container.decode(SessionStateMessage.self, forKey: .payload)
            self = .sessionState(payload)
        case .macRegistered:
            let payload = try container.decode(MacRegisteredMessage.self, forKey: .payload)
            self = .macRegistered(payload)
        case .command:
            let payload = try container.decode(CommandMessage.self, forKey: .payload)
            self = .command(payload)
        case .iosConnected:
            let payload = try container.decode(DeviceConnectedMessage.self, forKey: .payload)
            self = .iosConnected(payload)
        case .iosDisconnected:
            self = .iosDisconnected
        case .macViewerConnected:
            let payload = try container.decode(DeviceConnectedMessage.self, forKey: .payload)
            self = .macViewerConnected(payload)
        case .macViewerDisconnected:
            self = .macViewerDisconnected
        case .registerIOS:
            let payload = try container.decode(RegisterIOSMessage.self, forKey: .payload)
            self = .registerIOS(payload)
        case .requestSessionState:
            self = .requestSessionState
        case .registerPushToken:
            let payload = try container.decode(RegisterPushTokenMessage.self, forKey: .payload)
            self = .registerPushToken(payload)
        case .iosRegistered:
            let payload = try container.decode(IOSRegisteredMessage.self, forKey: .payload)
            self = .iosRegistered(payload)
        case .pushTokenRegistered:
            let payload = try container.decode(PushTokenRegisteredMessage.self, forKey: .payload)
            self = .pushTokenRegistered(payload)
        case .macConnected:
            let payload = try container.decode(DeviceConnectedMessage.self, forKey: .payload)
            self = .macConnected(payload)
        case .macDisconnected:
            self = .macDisconnected
        case .registerMacViewer:
            let payload = try container.decode(RegisterMacViewerMessage.self, forKey: .payload)
            self = .registerMacViewer(payload)
        case .macViewerRegistered:
            let payload = try container.decode(MacViewerRegisteredMessage.self, forKey: .payload)
            self = .macViewerRegistered(payload)
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
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .registerMac(payload):
            try container.encode(MessageType.registerMac, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .hookEvent(payload):
            try container.encode(MessageType.hookEvent, forKey: .type)
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
        case let .macRegistered(payload):
            try container.encode(MessageType.macRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .command(payload):
            try container.encode(MessageType.command, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .iosConnected(payload):
            try container.encode(MessageType.iosConnected, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .iosDisconnected:
            try container.encode(MessageType.iosDisconnected, forKey: .type)
        case let .macViewerConnected(payload):
            try container.encode(MessageType.macViewerConnected, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .macViewerDisconnected:
            try container.encode(MessageType.macViewerDisconnected, forKey: .type)
        case let .registerIOS(payload):
            try container.encode(MessageType.registerIOS, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .requestSessionState:
            try container.encode(MessageType.requestSessionState, forKey: .type)
        case let .registerPushToken(payload):
            try container.encode(MessageType.registerPushToken, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .iosRegistered(payload):
            try container.encode(MessageType.iosRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .pushTokenRegistered(payload):
            try container.encode(MessageType.pushTokenRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .macConnected(payload):
            try container.encode(MessageType.macConnected, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .macDisconnected:
            try container.encode(MessageType.macDisconnected, forKey: .type)
        case let .registerMacViewer(payload):
            try container.encode(MessageType.registerMacViewer, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .macViewerRegistered(payload):
            try container.encode(MessageType.macViewerRegistered, forKey: .type)
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
        }
    }

    /// Human-readable message type for logging
    var messageType: String {
        switch self {
        case .registerMac: MessageType.registerMac.rawValue
        case .hookEvent: MessageType.hookEvent.rawValue
        case .commandResponse: MessageType.commandResponse.rawValue
        case .terminalStream: MessageType.terminalStream.rawValue
        case .sessionState: MessageType.sessionState.rawValue
        case .macRegistered: MessageType.macRegistered.rawValue
        case .command: MessageType.command.rawValue
        case .iosConnected: MessageType.iosConnected.rawValue
        case .iosDisconnected: MessageType.iosDisconnected.rawValue
        case .macViewerConnected: MessageType.macViewerConnected.rawValue
        case .macViewerDisconnected: MessageType.macViewerDisconnected.rawValue
        case .registerIOS: MessageType.registerIOS.rawValue
        case .requestSessionState: MessageType.requestSessionState.rawValue
        case .registerPushToken: MessageType.registerPushToken.rawValue
        case .iosRegistered: MessageType.iosRegistered.rawValue
        case .pushTokenRegistered: MessageType.pushTokenRegistered.rawValue
        case .macConnected: MessageType.macConnected.rawValue
        case .macDisconnected: MessageType.macDisconnected.rawValue
        case .registerMacViewer: MessageType.registerMacViewer.rawValue
        case .macViewerRegistered: MessageType.macViewerRegistered.rawValue
        case .ping: MessageType.ping.rawValue
        case .pong: MessageType.pong.rawValue
        case .error: MessageType.error.rawValue
        case .encrypted: MessageType.encrypted.rawValue
        case .encryptedPush: MessageType.encryptedPush.rawValue
        }
    }
}

// MARK: - Encryption Extensions

public extension WebSocketMessage {
    /// Whether this message type should be encrypted for E2EE.
    var shouldEncrypt: Bool {
        switch self {
        case .hookEvent,
             .sessionState,
             .command,
             .commandResponse,
             .terminalStream:
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
