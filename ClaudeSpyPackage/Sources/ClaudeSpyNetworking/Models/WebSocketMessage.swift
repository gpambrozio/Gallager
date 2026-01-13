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

    /// Mac sends a terminal snapshot response
    case terminalSnapshot(TerminalSnapshotMessage)

    /// Mac confirms terminal stream started with initial content
    case terminalStreamStarted(TerminalStreamStartedMessage)

    /// Mac sends streaming terminal data chunk
    case terminalStreamData(TerminalStreamDataMessage)

    /// Mac sends terminal resize during streaming
    case terminalStreamResize(TerminalStreamResizeMessage)

    /// Mac notifies that terminal streaming has stopped
    case terminalStreamStopped(TerminalStreamStoppedMessage)

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
public struct EncryptedWebSocketMessage: Codable, Sendable {
    /// The type of message contained in the encrypted payload.
    /// Allows routing without decryption.
    public let innerType: EncryptedMessageType

    /// The encrypted payload (ciphertext + sender key ID + version)
    public let payload: EncryptedPayload

    public init(innerType: EncryptedMessageType, payload: EncryptedPayload) {
        self.innerType = innerType
        self.payload = payload
    }
}

/// Types of messages that can be encrypted.
/// Server uses this for routing without seeing content.
public enum EncryptedMessageType: String, Codable, Sendable {
    /// Hook event from Mac to iOS
    case hookEvent

    /// Session state from Mac to iOS
    case sessionState

    /// Command from iOS to Mac
    case command

    /// Command response from Mac to iOS
    case commandResponse

    /// Terminal snapshot from Mac to iOS
    case terminalSnapshot

    /// Terminal stream started from Mac to iOS
    case terminalStreamStarted

    /// Terminal stream data from Mac to iOS
    case terminalStreamData

    /// Terminal stream resize from Mac to iOS
    case terminalStreamResize

    /// Terminal stream stopped from Mac to iOS
    case terminalStreamStopped
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
        case terminalSnapshot
        case terminalStreamStarted
        case terminalStreamData
        case terminalStreamResize
        case terminalStreamStopped
        case sessionState
        case macRegistered
        case command
        case iosConnected
        case iosDisconnected
        case registerIOS
        case requestSessionState
        case registerPushToken
        case iosRegistered
        case pushTokenRegistered
        case macConnected
        case macDisconnected
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
        case .terminalSnapshot:
            let payload = try container.decode(TerminalSnapshotMessage.self, forKey: .payload)
            self = .terminalSnapshot(payload)
        case .terminalStreamStarted:
            let payload = try container.decode(TerminalStreamStartedMessage.self, forKey: .payload)
            self = .terminalStreamStarted(payload)
        case .terminalStreamData:
            let payload = try container.decode(TerminalStreamDataMessage.self, forKey: .payload)
            self = .terminalStreamData(payload)
        case .terminalStreamResize:
            let payload = try container.decode(TerminalStreamResizeMessage.self, forKey: .payload)
            self = .terminalStreamResize(payload)
        case .terminalStreamStopped:
            let payload = try container.decode(TerminalStreamStoppedMessage.self, forKey: .payload)
            self = .terminalStreamStopped(payload)
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
        case let .terminalSnapshot(payload):
            try container.encode(MessageType.terminalSnapshot, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .terminalStreamStarted(payload):
            try container.encode(MessageType.terminalStreamStarted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .terminalStreamData(payload):
            try container.encode(MessageType.terminalStreamData, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .terminalStreamResize(payload):
            try container.encode(MessageType.terminalStreamResize, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .terminalStreamStopped(payload):
            try container.encode(MessageType.terminalStreamStopped, forKey: .type)
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
        case .terminalSnapshot: MessageType.terminalSnapshot.rawValue
        case .terminalStreamStarted: MessageType.terminalStreamStarted.rawValue
        case .terminalStreamData: MessageType.terminalStreamData.rawValue
        case .terminalStreamResize: MessageType.terminalStreamResize.rawValue
        case .terminalStreamStopped: MessageType.terminalStreamStopped.rawValue
        case .sessionState: MessageType.sessionState.rawValue
        case .macRegistered: MessageType.macRegistered.rawValue
        case .command: MessageType.command.rawValue
        case .iosConnected: MessageType.iosConnected.rawValue
        case .iosDisconnected: MessageType.iosDisconnected.rawValue
        case .registerIOS: MessageType.registerIOS.rawValue
        case .requestSessionState: MessageType.requestSessionState.rawValue
        case .registerPushToken: MessageType.registerPushToken.rawValue
        case .iosRegistered: MessageType.iosRegistered.rawValue
        case .pushTokenRegistered: MessageType.pushTokenRegistered.rawValue
        case .macConnected: MessageType.macConnected.rawValue
        case .macDisconnected: MessageType.macDisconnected.rawValue
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
             .terminalSnapshot,
             .terminalStreamStarted,
             .terminalStreamData,
             .terminalStreamResize,
             .terminalStreamStopped:
            true
        default:
            false
        }
    }

    /// The encrypted message type for this message.
    /// Returns nil for messages that shouldn't be encrypted.
    var encryptedType: EncryptedMessageType? {
        switch self {
        case .hookEvent: .hookEvent
        case .sessionState: .sessionState
        case .command: .command
        case .commandResponse: .commandResponse
        case .terminalSnapshot: .terminalSnapshot
        case .terminalStreamStarted: .terminalStreamStarted
        case .terminalStreamData: .terminalStreamData
        case .terminalStreamResize: .terminalStreamResize
        case .terminalStreamStopped: .terminalStreamStopped
        default: nil
        }
    }

    #if canImport(Security)
        /// Encrypts this message using the provided E2EE service.
        /// - Parameter e2eeService: The E2EE service to use for encryption
        /// - Returns: An encrypted WebSocket message wrapper
        /// - Throws: Encryption or encoding errors
        func encrypt(using e2eeService: E2EEService) async throws -> WebSocketMessage {
            guard let innerType = encryptedType else {
                // Non-encryptable messages are returned as-is
                return self
            }

            // Encode the inner payload to JSON
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let innerData = try encoder.encode(self)

            // Encrypt the inner payload
            let encryptedPayload = try await e2eeService.encrypt(innerData)

            // Wrap in encrypted message
            return .encrypted(EncryptedWebSocketMessage(
                innerType: innerType,
                payload: encryptedPayload
            ))
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
