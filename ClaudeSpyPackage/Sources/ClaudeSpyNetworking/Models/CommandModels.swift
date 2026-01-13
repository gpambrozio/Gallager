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

// MARK: - Command Spec Protocol

/// Protocol that maps a command to its expected response type.
/// Used for type-safe command sending on the client side.
public protocol CommandSpec: Codable, Sendable {
    /// The response type this command expects
    associatedtype Response: Sendable

    /// Wrap this spec in the CommandType enum for wire format
    var commandType: CommandType { get }
}

// MARK: - Concrete Command Specs

/// Send keystrokes to a tmux pane. Returns success/failure.
public struct SendKeystroke: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public let keystrokes: [TmuxKey]

    public init(_ keystrokes: [TmuxKey]) {
        self.keystrokes = keystrokes
    }

    public var commandType: CommandType {
        .sendKeystroke(self)
    }
}

/// Cancel the current operation (Ctrl+C). Returns success/failure.
public struct CancelOperation: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .cancelOperation(self)
    }
}

/// Capture a terminal snapshot. Returns the snapshot data.
public struct CaptureSnapshot: CommandSpec, Equatable {
    public typealias Response = TerminalSnapshotMessage

    public let scrollbackMultiplier: Int

    public init(scrollbackMultiplier: Int) {
        self.scrollbackMultiplier = scrollbackMultiplier
    }

    public var commandType: CommandType {
        .captureSnapshot(self)
    }
}

/// Start streaming terminal data from a pane. Returns initial state.
public struct StartTerminalStream: CommandSpec, Equatable {
    public typealias Response = TerminalStreamStartedMessage

    public init() { }

    public var commandType: CommandType {
        .startTerminalStream(self)
    }
}

/// Stop streaming terminal data from a pane. Returns success/failure.
public struct StopTerminalStream: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .stopTerminalStream(self)
    }
}

// MARK: - Command Types

/// Commands that can be sent from iOS to Mac, with their associated data.
/// This enum is the wire format - it's what gets encoded and sent over the network.
/// Each case holds its corresponding CommandSpec struct.
public enum CommandType: Codable, Sendable, Equatable {
    /// Send keystrokes to a tmux pane
    case sendKeystroke(SendKeystroke)
    /// Cancel current operation (Ctrl+C)
    case cancelOperation(CancelOperation)
    /// Capture a terminal snapshot with scrollback
    case captureSnapshot(CaptureSnapshot)
    /// Start streaming terminal data from a pane
    case startTerminalStream(StartTerminalStream)
    /// Stop streaming terminal data from a pane
    case stopTerminalStream(StopTerminalStream)

    // MARK: - Convenience Factory Methods

    /// Create a sendKeystroke command from an array of keys
    public static func sendKeystroke(_ keys: [TmuxKey]) -> CommandType {
        .sendKeystroke(SendKeystroke(keys))
    }

    /// Create a cancelOperation command
    public static var cancelOperation: CommandType {
        .cancelOperation(CancelOperation())
    }

    /// Create a captureSnapshot command with the given scrollback multiplier
    public static func captureSnapshot(scrollbackMultiplier: Int) -> CommandType {
        .captureSnapshot(CaptureSnapshot(scrollbackMultiplier: scrollbackMultiplier))
    }

    /// Create a startTerminalStream command
    public static var startTerminalStream: CommandType {
        .startTerminalStream(StartTerminalStream())
    }

    /// Create a stopTerminalStream command
    public static var stopTerminalStream: CommandType {
        .stopTerminalStream(StopTerminalStream())
    }
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

// MARK: - Terminal Stream Messages

/// Response when terminal streaming starts, containing initial terminal state
public struct TerminalStreamStartedMessage: Codable, Sendable, Identifiable {
    public var id: UUID { commandId }

    /// The command ID this message responds to
    public let commandId: UUID

    /// The pane ID being streamed
    public let paneId: String

    /// Terminal width in character columns
    public let width: Int

    /// Terminal height in character rows
    public let height: Int

    /// Initial content as Base64-encoded data (raw bytes with ANSI escape sequences)
    public let initialContentBase64: String

    public init(
        commandId: UUID,
        paneId: String,
        width: Int,
        height: Int,
        initialContent: Data
    ) {
        self.commandId = commandId
        self.paneId = paneId
        self.width = width
        self.height = height
        self.initialContentBase64 = initialContent.base64EncodedString()
    }

    /// Decodes the initial content from Base64
    public var initialContent: Data? {
        Data(base64Encoded: initialContentBase64)
    }
}

/// Streaming terminal data chunk sent from Mac to iOS
public struct TerminalStreamDataMessage: Codable, Sendable {
    /// The pane ID the data belongs to
    public let paneId: String

    /// The terminal data as Base64-encoded bytes (raw ANSI escape sequences)
    public let dataBase64: String

    public init(paneId: String, data: Data) {
        self.paneId = paneId
        self.dataBase64 = data.base64EncodedString()
    }

    /// Decodes the data from Base64
    public var data: Data? {
        Data(base64Encoded: dataBase64)
    }
}

/// Terminal resize notification sent from Mac to iOS during streaming
public struct TerminalStreamResizeMessage: Codable, Sendable {
    /// The pane ID being resized
    public let paneId: String

    /// New terminal width in character columns
    public let width: Int

    /// New terminal height in character rows
    public let height: Int

    public init(paneId: String, width: Int, height: Int) {
        self.paneId = paneId
        self.width = width
        self.height = height
    }
}

/// Notification that terminal streaming has stopped
public struct TerminalStreamStoppedMessage: Codable, Sendable {
    /// The pane ID that stopped streaming
    public let paneId: String

    /// Reason for stopping (e.g., "user_requested", "pane_closed", "error")
    public let reason: String

    public init(paneId: String, reason: String) {
        self.paneId = paneId
        self.reason = reason
    }
}
