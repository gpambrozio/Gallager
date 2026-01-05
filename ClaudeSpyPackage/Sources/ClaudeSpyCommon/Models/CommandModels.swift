import Foundation

// MARK: - Command Types

/// Types of commands that can be sent from iOS to Mac
public enum CommandType: String, Codable, Sendable {
    /// Send keystrokes to a tmux pane
    case sendKeystroke
    /// Cancel current operation (Ctrl+C)
    case cancelOperation
    /// Pause mirror streaming
    case pauseMirror
    /// Resume mirror streaming
    case resumeMirror
}

// MARK: - Command Message

/// A command sent from iOS to Mac via the relay server
public struct CommandMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let paneId: String
    public let type: CommandType
    public let payload: [String: AnyCodable]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        paneId: String,
        type: CommandType,
        payload: [String: AnyCodable] = [:],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.paneId = paneId
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }

    /// Create a keystroke command
    public static func keystroke(paneId: String, keys: String) -> CommandMessage {
        CommandMessage(
            paneId: paneId,
            type: .sendKeystroke,
            payload: ["keys": AnyCodable(keys)]
        )
    }

    /// Create a cancel operation command (Ctrl+C)
    public static func cancel(paneId: String) -> CommandMessage {
        CommandMessage(
            paneId: paneId,
            type: .cancelOperation
        )
    }
}

// MARK: - Command Response

/// Response to a command execution
public struct CommandResponseMessage: Codable, Sendable {
    public let commandId: UUID
    public let success: Bool
    public let error: String?

    public init(commandId: UUID, success: Bool, error: String? = nil) {
        self.commandId = commandId
        self.success = success
        self.error = error
    }

    public static func success(for commandId: UUID) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: true)
    }

    public static func failure(for commandId: UUID, error: String) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: false, error: error)
    }
}
