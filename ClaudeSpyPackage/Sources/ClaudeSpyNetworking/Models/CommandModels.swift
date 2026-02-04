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

    /// Command key combinations (e.g., .cmd("v") for Cmd+V)
    /// Sent as CSI u escape sequence for modern terminal support
    case cmd(Character)

    /// Delay in milliseconds (not a real key, handled specially by executor)
    case delay(Int)

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
        // CSI u format: ESC [ keycode ; modifier u (modifier 9 = Super/Cmd)
        case let .cmd(char): "\u{1b}[\(char.asciiValue ?? 0);9u"
        case .delay: "" // Not a real key, handled by executor
        }
    }

    /// Whether this key requires tmux literal mode (sends text as-is without interpretation).
    /// Applies to `.text` and `.cmd` (escape sequences must be sent literally).
    public var requiresLiteralMode: Bool {
        switch self {
        case .text,
             .cmd: true
        default: false
        }
    }
}

// MARK: - Byte Parsing

public extension TmuxKey {
    /// Converts raw terminal bytes to an array of TmuxKey representations.
    ///
    /// Parses escape sequences (arrow keys, etc.), control characters, and regular text.
    /// This is the inverse of what tmux send-keys does - we take what SwiftTerm gives us
    /// and convert it back to logical keystrokes.
    ///
    /// - Parameter data: Raw bytes from the terminal (e.g., from TerminalViewDelegate.send)
    /// - Returns: Array of TmuxKey values ready for transmission
    static func from(bytes data: Data) -> [TmuxKey] {
        var result: [TmuxKey] = []
        var index = data.startIndex
        var textBuffer = ""

        // Flush accumulated text to results
        func flushText() {
            if !textBuffer.isEmpty {
                result.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        while index < data.endIndex {
            let byte = data[index]

            // Check for escape sequence
            if byte == 0x1B, index + 1 < data.endIndex {
                let nextByte = data[index + 1]

                // CSI sequence: ESC [
                if nextByte == 0x5B, index + 2 < data.endIndex {
                    let seqByte = data[index + 2]

                    // Arrow keys and simple CSI sequences
                    switch seqByte {
                    case 0x41: // A - Up
                        flushText()
                        result.append(.up)
                        index = data.index(index, offsetBy: 3)
                        continue
                    case 0x42: // B - Down
                        flushText()
                        result.append(.down)
                        index = data.index(index, offsetBy: 3)
                        continue
                    case 0x43: // C - Right
                        flushText()
                        result.append(.right)
                        index = data.index(index, offsetBy: 3)
                        continue
                    case 0x44: // D - Left
                        flushText()
                        result.append(.left)
                        index = data.index(index, offsetBy: 3)
                        continue
                    case 0x48: // H - Home
                        flushText()
                        result.append(.home)
                        index = data.index(index, offsetBy: 3)
                        continue
                    case 0x46: // F - End
                        flushText()
                        result.append(.end)
                        index = data.index(index, offsetBy: 3)
                        continue
                    default:
                        break
                    }

                    // Extended sequences: ESC [ n ~
                    if index + 3 < data.endIndex, data[index + 3] == 0x7E {
                        switch seqByte {
                        case 0x33: // 3~ - Delete
                            flushText()
                            result.append(.delete)
                            index = data.index(index, offsetBy: 4)
                            continue
                        case 0x35: // 5~ - Page Up
                            flushText()
                            result.append(.pageUp)
                            index = data.index(index, offsetBy: 4)
                            continue
                        case 0x36: // 6~ - Page Down
                            flushText()
                            result.append(.pageDown)
                            index = data.index(index, offsetBy: 4)
                            continue
                        default:
                            break
                        }
                    }

                    // Unrecognized CSI sequence - consume ESC [ and next byte to avoid infinite loop
                    flushText()
                    result.append(.escape)
                    index = data.index(index, offsetBy: 3)
                    continue
                }

                // Alt+letter: ESC followed by letter (meta key)
                if nextByte >= 0x20, nextByte < 0x7F {
                    // For now, pass through as escape + character
                    // Could add .alt(Character) case if needed
                    flushText()
                    result.append(.escape)
                    index = data.index(after: index)
                    continue
                }

                // Bare escape
                flushText()
                result.append(.escape)
                index = data.index(after: index)
                continue
            }

            // Control characters
            // Note: Order matters! Specific cases must come before the range.
            switch byte {
            case 0x00: // Ctrl+@ or Ctrl+Space
                flushText()
                result.append(.ctrl("@"))
            case 0x09: // Tab (Ctrl+I generates 0x09, but Tab is the expected behavior)
                flushText()
                result.append(.tab)
            case 0x0A,
                 0x0D: // Line feed, Carriage return → Enter
                flushText()
                result.append(.enter)
            case 0x01...0x1A: // Ctrl+A through Ctrl+Z (excluding 0x09, 0x0A, 0x0D handled above)
                flushText()
                let letter = Character(UnicodeScalar(byte - 1 + UInt8(ascii: "a")))
                result.append(.ctrl(letter))
            case 0x1B: // Escape (bare, handled above for sequences)
                flushText()
                result.append(.escape)
            case 0x20: // Space
                flushText()
                result.append(.space)
            case 0x7F: // DEL - typically backspace on modern terminals
                flushText()
                result.append(.backspace)
            case 0x21...0x7E: // Printable ASCII
                textBuffer.append(Character(UnicodeScalar(byte)))
            default:
                // High bytes - try to decode as UTF-8
                let remaining = data[index...]
                if
                    let string = String(data: Data(remaining.prefix(4)), encoding: .utf8),
                    let char = string.first {
                    textBuffer.append(char)
                    let charBytes = String(char).utf8.count
                    index = data.index(index, offsetBy: charBytes)
                    continue
                }
                // Invalid UTF-8 byte - use replacement character instead of silently dropping
                textBuffer.append("\u{FFFD}")
            }

            index = data.index(after: index)
        }

        flushText()
        return result
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

/// Start streaming terminal output to iOS. Returns success/failure.
public struct StartTerminalStream: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .startTerminalStream(self)
    }
}

/// Stop streaming terminal output to iOS. Returns success/failure.
public struct StopTerminalStream: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .stopTerminalStream(self)
    }
}

/// Create a new tmux session. Returns success/failure.
public struct CreateTmuxSession: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// Base name for the session
    public let sessionName: String

    /// Terminal width in columns
    public let width: Int

    /// Terminal height in rows
    public let height: Int

    /// Optional working directory to start the session in
    public let workingDirectory: String?

    public init(sessionName: String, width: Int, height: Int, workingDirectory: String? = nil) {
        self.sessionName = sessionName
        self.width = width
        self.height = height
        self.workingDirectory = workingDirectory
    }

    public var commandType: CommandType {
        .createTmuxSession(self)
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
    /// Start streaming terminal output
    case startTerminalStream(StartTerminalStream)
    /// Stop streaming terminal output
    case stopTerminalStream(StopTerminalStream)
    /// Create a new tmux session
    case createTmuxSession(CreateTmuxSession)

    // MARK: - Convenience Factory Methods

    /// Create a sendKeystroke command from an array of keys
    public static func sendKeystroke(_ keys: [TmuxKey]) -> CommandType {
        .sendKeystroke(SendKeystroke(keys))
    }

    /// Create a cancelOperation command
    public static var cancelOperation: CommandType {
        .cancelOperation(CancelOperation())
    }

    /// Create a startTerminalStream command
    public static var startTerminalStream: CommandType {
        .startTerminalStream(StartTerminalStream())
    }

    /// Create a stopTerminalStream command
    public static var stopTerminalStream: CommandType {
        .stopTerminalStream(StopTerminalStream())
    }

    /// Create a createTmuxSession command
    public static func createTmuxSession(
        sessionName: String,
        width: Int,
        height: Int,
        workingDirectory: String? = nil
    ) -> CommandType {
        .createTmuxSession(CreateTmuxSession(
            sessionName: sessionName,
            width: width,
            height: height,
            workingDirectory: workingDirectory
        ))
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
    /// Optional pane ID returned by commands that create or affect panes
    public let paneId: String?

    public init(commandId: UUID, success: Bool, error: String? = nil, paneId: String? = nil) {
        self.commandId = commandId
        self.success = success
        self.error = error
        self.paneId = paneId
    }

    public static func success(for commandId: UUID, paneId: String? = nil) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: true, paneId: paneId)
    }

    public static func failure(for commandId: UUID, error: String) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: false, error: error)
    }
}
