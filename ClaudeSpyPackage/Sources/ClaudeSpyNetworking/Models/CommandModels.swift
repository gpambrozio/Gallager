import Foundation

// MARK: - Character Codable

extension Character: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let char = string.first, string.count == 1 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected single character"
            )
        }
        self = char
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(self))
    }
}

// MARK: - Tmux Key

/// Represents a keystroke to send to tmux.
/// Either literal text or a special key that tmux interprets.
public enum TmuxKey: Codable, Sendable, Equatable {
    /// Literal text to send as-is
    case text(String)

    /// Special keys that tmux interprets
    case enter
    case escape
    case tab
    case space
    case backspace
    case delete

    /// Arrow keys
    case up
    case down
    case left
    case right

    /// Navigation keys
    case home
    case end
    case pageUp
    case pageDown

    /// Control key combinations (e.g., .ctrl("c") for Ctrl+C)
    case ctrl(Character)

    /// The tmux key name for special keys, or the literal text
    public var tmuxKeyName: String {
        switch self {
        case let .text(string): string
        case .enter: "Enter"
        case .escape: "Escape"
        case .tab: "Tab"
        case .space: "Space"
        case .backspace: "BSpace"
        case .delete: "Delete"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PageUp"
        case .pageDown: "PageDown"
        case let .ctrl(char): "C-\(char)"
        }
    }

    /// Whether this key should be sent literally (without tmux interpretation)
    public var isLiteral: Bool {
        if case .text = self { return true }
        return false
    }
}

// MARK: - Command Types

/// Commands that can be sent from iOS to Mac, with their associated data.
public enum CommandType: Codable, Sendable {
    /// Send keystrokes to a tmux pane
    case sendKeystroke([TmuxKey])
    /// Cancel current operation (Ctrl+C)
    case cancelOperation
    /// Start streaming terminal content from a pane
    case startStream
    /// Stop streaming terminal content from a pane
    case stopStream
}

// MARK: - Command Message

/// A command sent from iOS to Mac via the relay server
public struct CommandMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let paneId: String
    public let command: CommandType
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        paneId: String,
        command: CommandType,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.paneId = paneId
        self.command = command
        self.timestamp = timestamp
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

// MARK: - Terminal Stream

/// A chunk of streaming terminal data sent from Mac to iOS
public struct TerminalStreamChunk: Codable, Sendable {
    /// The pane ID being streamed
    public let paneId: String

    /// Terminal width in character columns
    public let width: Int

    /// Terminal height in character rows
    public let height: Int

    /// The chunk of terminal data as Base64-encoded bytes (raw ANSI escape sequences)
    public let dataBase64: String

    /// Whether this is the initial content (includes cursor positioning)
    public let isInitial: Bool

    public init(
        paneId: String,
        width: Int,
        height: Int,
        data: Data,
        isInitial: Bool = false
    ) {
        self.paneId = paneId
        self.width = width
        self.height = height
        self.dataBase64 = data.base64EncodedString()
        self.isInitial = isInitial
    }

    /// Decodes the data from Base64
    public var data: Data? {
        Data(base64Encoded: dataBase64)
    }
}

/// Message sent when a stream starts, containing initial state
public struct TerminalStreamStarted: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID { commandId }

    /// The command ID that requested the stream
    public let commandId: UUID

    /// The pane ID being streamed
    public let paneId: String

    /// Terminal width in character columns
    public let width: Int

    /// Terminal height in character rows
    public let height: Int

    public init(
        commandId: UUID,
        paneId: String,
        width: Int,
        height: Int
    ) {
        self.commandId = commandId
        self.paneId = paneId
        self.width = width
        self.height = height
    }
}

/// Message sent when a stream stops
public struct TerminalStreamStopped: Codable, Sendable {
    /// The pane ID that stopped streaming
    public let paneId: String

    /// Reason for stopping (nil if stopped by user request)
    public let reason: String?

    public init(paneId: String, reason: String? = nil) {
        self.paneId = paneId
        self.reason = reason
    }
}
