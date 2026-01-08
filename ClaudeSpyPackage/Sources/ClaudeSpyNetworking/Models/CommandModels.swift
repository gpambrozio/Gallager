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
    /// Capture a terminal snapshot with scrollback (multiplier for visible height)
    case captureSnapshot(scrollbackMultiplier: Int)
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

// MARK: - Terminal Snapshot

/// Response containing a terminal snapshot with content and dimensions
public struct TerminalSnapshotMessage: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID { commandId }
    /// The command ID this snapshot responds to
    public let commandId: UUID

    /// The pane ID that was captured
    public let paneId: String

    /// Terminal width in character columns
    public let width: Int

    /// Terminal height in character rows (visible area)
    public let height: Int

    /// Total number of lines including scrollback
    public let totalLines: Int

    /// The captured content as Base64-encoded data (raw bytes with ANSI escape sequences)
    public let contentBase64: String

    public init(
        commandId: UUID,
        paneId: String,
        width: Int,
        height: Int,
        totalLines: Int,
        content: Data
    ) {
        self.commandId = commandId
        self.paneId = paneId
        self.width = width
        self.height = height
        self.totalLines = totalLines
        self.contentBase64 = content.base64EncodedString()
    }

    /// Decodes the content from Base64
    public var content: Data? {
        Data(base64Encoded: contentBase64)
    }
}
