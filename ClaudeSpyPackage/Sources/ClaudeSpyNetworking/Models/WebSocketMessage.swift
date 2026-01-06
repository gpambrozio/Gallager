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

    /// Mac sends complete session state (on iOS connect or request)
    case sessionState(SessionStateMessage)

    // MARK: - Server → Mac

    /// Server confirms Mac registration
    case macRegistered(MacRegisteredMessage)

    /// Server relays a command from iOS
    case command(CommandMessage)

    /// Server notifies Mac that iOS has connected
    case iosConnected

    /// Server notifies Mac that iOS has disconnected
    case iosDisconnected

    // MARK: - iOS → Server

    /// iOS registers with the relay server after connecting
    case registerIOS(RegisterIOSMessage)

    /// iOS sends a command to be relayed to Mac
    // (Uses same `command` case as Server → Mac for symmetry)

    /// iOS requests current session state from Mac
    case requestSessionState

    // MARK: - Server → iOS

    /// Server confirms iOS registration
    case iosRegistered(IOSRegisteredMessage)

    /// Server notifies iOS that Mac has connected
    case macConnected

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

extension WebSocketMessage {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case registerMac
        case hookEvent
        case commandResponse
        case terminalSnapshot
        case sessionState
        case macRegistered
        case command
        case iosConnected
        case iosDisconnected
        case registerIOS
        case requestSessionState
        case iosRegistered
        case macConnected
        case macDisconnected
        case ping
        case pong
        case error
    }

    public init(from decoder: Decoder) throws {
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
            self = .iosConnected
        case .iosDisconnected:
            self = .iosDisconnected
        case .registerIOS:
            let payload = try container.decode(RegisterIOSMessage.self, forKey: .payload)
            self = .registerIOS(payload)
        case .requestSessionState:
            self = .requestSessionState
        case .iosRegistered:
            let payload = try container.decode(IOSRegisteredMessage.self, forKey: .payload)
            self = .iosRegistered(payload)
        case .macConnected:
            self = .macConnected
        case .macDisconnected:
            self = .macDisconnected
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        case .error:
            let payload = try container.decode(ErrorMessage.self, forKey: .payload)
            self = .error(payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
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
        case let .sessionState(payload):
            try container.encode(MessageType.sessionState, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .macRegistered(payload):
            try container.encode(MessageType.macRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .command(payload):
            try container.encode(MessageType.command, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .iosConnected:
            try container.encode(MessageType.iosConnected, forKey: .type)
        case .iosDisconnected:
            try container.encode(MessageType.iosDisconnected, forKey: .type)
        case let .registerIOS(payload):
            try container.encode(MessageType.registerIOS, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .requestSessionState:
            try container.encode(MessageType.requestSessionState, forKey: .type)
        case let .iosRegistered(payload):
            try container.encode(MessageType.iosRegistered, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .macConnected:
            try container.encode(MessageType.macConnected, forKey: .type)
        case .macDisconnected:
            try container.encode(MessageType.macDisconnected, forKey: .type)
        case .ping:
            try container.encode(MessageType.ping, forKey: .type)
        case .pong:
            try container.encode(MessageType.pong, forKey: .type)
        case let .error(payload):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }

    /// Human-readable message type for logging
    public var messageType: String {
        switch self {
        case .registerMac: "registerMac"
        case .hookEvent: "hookEvent"
        case .commandResponse: "commandResponse"
        case .terminalSnapshot: "terminalSnapshot"
        case .sessionState: "sessionState"
        case .macRegistered: "macRegistered"
        case .command: "command"
        case .iosConnected: "iosConnected"
        case .iosDisconnected: "iosDisconnected"
        case .registerIOS: "registerIOS"
        case .requestSessionState: "requestSessionState"
        case .iosRegistered: "iosRegistered"
        case .macConnected: "macConnected"
        case .macDisconnected: "macDisconnected"
        case .ping: "ping"
        case .pong: "pong"
        case .error: "error"
        }
    }
}
