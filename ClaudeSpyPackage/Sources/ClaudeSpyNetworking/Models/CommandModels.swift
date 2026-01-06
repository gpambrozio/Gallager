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
    /// Capture a terminal snapshot with scrollback
    case captureSnapshot
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

    /// Create a capture snapshot command
    /// - Parameters:
    ///   - paneId: The pane ID to capture
    ///   - scrollbackMultiplier: How many times the visible height to capture as scrollback (default: 3)
    public static func captureSnapshot(paneId: String, scrollbackMultiplier: Int = 3) -> CommandMessage {
        CommandMessage(
            paneId: paneId,
            type: .captureSnapshot,
            payload: ["scrollbackMultiplier": AnyCodable(scrollbackMultiplier)]
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
