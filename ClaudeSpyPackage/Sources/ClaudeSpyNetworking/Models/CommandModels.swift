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
    case backtab
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

    /// Alt/Meta key combinations (e.g., .alt("b") for Meta-b / word backward)
    case alt(Character)

    /// Control+Alt key combinations (e.g., .ctrlAlt("x") for Ctrl+Alt+X)
    case ctrlAlt(Character)

    /// Delay in milliseconds (not a real key, handled specially by executor)
    case delay(Int)

    /// The tmux key name for special keys, or the literal text
    public var tmuxKeyName: String {
        switch self {
        case let .text(string): string
        case .enter: "Enter"
        case .escape: "Escape"
        case .tab: "Tab"
        case .backtab: "BTab"
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
        case let .alt(char): "M-\(char)"
        case let .ctrlAlt(char): "C-M-\(char)"
        case .delay: "" // Not a real key, handled by executor
        }
    }

    /// Whether this key requires tmux literal mode (sends text as-is without interpretation).
    /// Only applies to `.text` - other cases like `.delay` are handled specially by the executor.
    public var requiresLiteralMode: Bool {
        if case .text = self { return true }
        return false
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
    /// Supports both legacy CSI sequences (e.g., `ESC [ C` for Right) and the kitty
    /// keyboard protocol's CSI u encoding (e.g., `ESC [ 97 ; 5 u` for Ctrl+A).
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
                    // Use general CSI parser that handles both simple and parameterized sequences
                    if let parsed = parseCsiSequence(data: data, escIndex: index) {
                        flushText()
                        result.append(contentsOf: parsed.keys)
                        index = parsed.nextIndex
                        continue
                    }

                    // Unrecognized or incomplete CSI — skip ESC byte only,
                    // let remaining bytes be processed normally
                    flushText()
                    result.append(.escape)
                    index = data.index(after: index)
                    continue
                }

                // Alt/Meta key: ESC followed by printable character
                if nextByte >= 0x20, nextByte < 0x7F {
                    flushText()
                    let char = Character(UnicodeScalar(nextByte))
                    result.append(.alt(char))
                    index = data.index(index, offsetBy: 2)
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
                // Determine expected character length from leading byte
                let charLen: Int
                switch byte {
                case 0xC0...0xDF: charLen = 2
                case 0xE0...0xEF: charLen = 3
                case 0xF0...0xF7: charLen = 4
                default: charLen = 1
                }
                let remaining = data[index...]
                if
                    remaining.count >= charLen,
                    let string = String(data: Data(remaining.prefix(charLen)), encoding: .utf8),
                    let char = string.first {
                    textBuffer.append(char)
                    index = data.index(index, offsetBy: charLen)
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

// MARK: - CSI Sequence Parsing

private extension TmuxKey {
    /// Result of parsing a CSI sequence.
    struct CsiParseResult {
        let keys: [TmuxKey]
        let nextIndex: Data.Index
    }

    /// Parses a CSI sequence starting at `escIndex` (pointing to ESC byte).
    ///
    /// Handles both simple sequences (`ESC [ C` for Right) and parameterized ones
    /// (`ESC [ 1 ; 5 C` for Ctrl+Right, `ESC [ 97 ; 5 u` for Ctrl+A in kitty protocol).
    ///
    /// Returns parsed keys and the index after the sequence, or nil if the sequence
    /// is incomplete or contains invalid bytes.
    static func parseCsiSequence(data: Data, escIndex: Data.Index) -> CsiParseResult? {
        // Start after ESC [
        var j = escIndex + 2
        var params: [Int] = []
        var currentParam = 0
        var hasDigit = false

        // Collect parameters: digits separated by semicolons
        while j < data.endIndex {
            let b = data[j]
            if b >= 0x30, b <= 0x39 { // '0'-'9'
                currentParam = currentParam &* 10 &+ Int(b - 0x30)
                // Cap at max Unicode codepoint to prevent wrapping on adversarial input
                if currentParam > 0x10FFFF { return nil }
                hasDigit = true
                j += 1
            } else if b == 0x3B { // ';'
                params.append(hasDigit ? currentParam : 0)
                currentParam = 0
                hasDigit = false
                j += 1
            } else if b >= 0x40, b <= 0x7E { // Final byte (@ through ~)
                if hasDigit || !params.isEmpty {
                    params.append(currentParam)
                }
                let nextIndex = j + 1
                return mapCsiFinalByte(params: params, finalByte: b, nextIndex: nextIndex)
            } else {
                return nil // Invalid byte in CSI params
            }
        }
        return nil // Incomplete sequence
    }

    /// Maps a CSI final byte (with parsed parameters) to TmuxKey values.
    static func mapCsiFinalByte(
        params: [Int],
        finalByte: UInt8,
        nextIndex: Data.Index
    ) -> CsiParseResult? {
        switch finalByte {
        case 0x41: // A — Up
            return CsiParseResult(keys: [.up], nextIndex: nextIndex)
        case 0x42: // B — Down
            return CsiParseResult(keys: [.down], nextIndex: nextIndex)
        case 0x43: // C — Right
            return CsiParseResult(keys: [.right], nextIndex: nextIndex)
        case 0x44: // D — Left
            return CsiParseResult(keys: [.left], nextIndex: nextIndex)
        case 0x48: // H — Home
            return CsiParseResult(keys: [.home], nextIndex: nextIndex)
        case 0x46: // F — End
            return CsiParseResult(keys: [.end], nextIndex: nextIndex)
        case 0x5A: // Z — Backtab (Shift+Tab)
            return CsiParseResult(keys: [.backtab], nextIndex: nextIndex)
        case 0x7E: // ~ — Extended key, dispatched on first param
            guard let code = params.first else { return nil }
            switch code {
            case 3: return CsiParseResult(keys: [.delete], nextIndex: nextIndex)
            case 5: return CsiParseResult(keys: [.pageUp], nextIndex: nextIndex)
            case 6: return CsiParseResult(keys: [.pageDown], nextIndex: nextIndex)
            default:
                // Unknown extended key — consume the sequence silently
                return CsiParseResult(keys: [], nextIndex: nextIndex)
            }
        case 0x75: // u — CSI u (kitty keyboard protocol key event)
            return mapCsiUKey(params: params, nextIndex: nextIndex)
        default:
            // Unknown final byte — consume the sequence to prevent garbage output
            return CsiParseResult(keys: [], nextIndex: nextIndex)
        }
    }

    /// Maps a CSI u (kitty keyboard protocol) sequence to TmuxKey values.
    ///
    /// Format: `ESC [ codepoint [; modifiers [; event-type]] u`
    ///
    /// Modifier encoding: value = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
    static func mapCsiUKey(params: [Int], nextIndex: Data.Index) -> CsiParseResult? {
        guard let codepoint = params.first, codepoint > 0 else {
            return CsiParseResult(keys: [], nextIndex: nextIndex)
        }

        let modifier = params.count >= 2 ? params[1] : 1
        let hasShift = (modifier &- 1) & 1 != 0
        let hasCtrl = (modifier &- 1) & 4 != 0
        let hasAlt = (modifier &- 1) & 2 != 0

        // Map well-known codepoints to their TmuxKey equivalents.
        // Modifier-aware: Shift+Tab → backtab, Ctrl+letter → ctrl(char).
        // Other modifier combinations on special keys (e.g., Ctrl+Enter) are
        // passed as the base key since TmuxKey has no representation for them.
        switch codepoint {
        case 9: return CsiParseResult(keys: [hasShift ? .backtab : .tab], nextIndex: nextIndex)
        case 13: return CsiParseResult(keys: [.enter], nextIndex: nextIndex)
        case 27: return CsiParseResult(keys: [.escape], nextIndex: nextIndex)
        case 32: return CsiParseResult(keys: [.space], nextIndex: nextIndex)
        case 127: return CsiParseResult(keys: [.backspace], nextIndex: nextIndex)
        default:
            guard let scalar = UnicodeScalar(codepoint) else {
                return CsiParseResult(keys: [], nextIndex: nextIndex)
            }
            let char = Character(scalar)
            if hasCtrl, hasAlt, char.isLetter {
                return CsiParseResult(
                    keys: [.ctrlAlt(Character(char.lowercased()))],
                    nextIndex: nextIndex
                )
            } else if hasCtrl, char.isLetter {
                return CsiParseResult(
                    keys: [.ctrl(Character(char.lowercased()))],
                    nextIndex: nextIndex
                )
            } else if hasAlt {
                return CsiParseResult(keys: [.alt(char)], nextIndex: nextIndex)
            } else {
                return CsiParseResult(
                    keys: [.text(String(char))],
                    nextIndex: nextIndex
                )
            }
        }
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

/// Resize a tmux pane to new dimensions. Returns success/failure.
public struct ResizeTmuxPane: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// Terminal width in columns
    public let width: Int

    /// Terminal height in rows
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var commandType: CommandType {
        .resizeTmuxPane(self)
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

/// Set a custom description for a tmux window. Returns success/failure.
/// The description is applied to all panes in the window and synced to all connected devices.
public struct SetWindowDescription: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// The window ID (sessionName:windowIndex) to set the description for
    public let windowId: String

    /// The custom description text, or nil to clear
    public let description: String?

    public init(windowId: String, description: String?) {
        self.windowId = windowId
        self.description = description
    }

    public var commandType: CommandType {
        .setWindowDescription(self)
    }
}

/// Set yolo mode for a pane's Claude session. Returns success/failure.
public struct SetYoloMode: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// Whether to enable or disable yolo mode
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public var commandType: CommandType {
        .setYoloMode(self)
    }
}

/// Mark a session as handled (user has seen it). Returns success/failure.
public struct MarkHandled: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .markHandled(self)
    }
}

/// Split a tmux pane horizontally or vertically. On success, the response's `paneId` field contains the newly created pane's ID.
public struct SplitTmuxPane: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// Direction to split
    public let direction: SplitDirection

    public init(direction: SplitDirection) {
        self.direction = direction
    }

    public var commandType: CommandType {
        .splitTmuxPane(self)
    }
}

/// Direction for splitting a tmux pane
public enum SplitDirection: String, Codable, Sendable {
    /// Split left-right (new pane appears to the right)
    case horizontal
    /// Split top-bottom (new pane appears below)
    case vertical
}

/// Select (focus) a tmux pane. Returns success/failure.
public struct SelectTmuxPane: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .selectTmuxPane(self)
    }
}

/// Select (switch to) a tmux window. Returns success/failure.
/// The window target is specified via the `paneId` field of the `CommandMessage`,
/// using the format "sessionName:windowIndex".
public struct SelectTmuxWindow: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .selectTmuxWindow(self)
    }
}

/// Send raw bytes (e.g., mouse escape sequences) to a tmux pane. Fire-and-forget.
public struct SendRawInput: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// Base64-encoded raw bytes to send directly to tmux via `send-keys -H`
    public let dataBase64: String

    public init(data: Data) {
        self.dataBase64 = data.base64EncodedString()
    }

    public var data: Data? {
        Data(base64Encoded: dataBase64)
    }

    public var commandType: CommandType {
        .sendRawInput(self)
    }
}

/// Create a new tmux window in an existing session. Returns success/failure.
/// On success, the response's `paneId` field contains the new window's first pane ID.
public struct CreateTmuxWindow: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// The session name to create the window in
    public let sessionName: String

    /// Optional working directory for the new window
    public let workingDirectory: String?

    public init(sessionName: String, workingDirectory: String? = nil) {
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
    }

    public var commandType: CommandType {
        .createTmuxWindow(self)
    }
}

/// Check running processes in a tmux window or session, for close confirmation.
/// Returns process info in the response's `runningProcesses` field.
public struct CheckRunningProcesses: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// What to check for running processes
    public enum Target: Codable, Sendable, Equatable {
        /// Check processes in a single window (window ID e.g. "session:0")
        case window(String)
        /// Check processes in an entire session
        case session(String)
    }

    public let target: Target

    public init(target: Target) {
        self.target = target
    }

    public var commandType: CommandType {
        .checkRunningProcesses(self)
    }
}

/// Kill (close) a tmux window. Returns success/failure.
public struct KillTmuxWindow: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// The window target (e.g. "session:0")
    public let windowId: String

    public init(windowId: String) {
        self.windowId = windowId
    }

    public var commandType: CommandType {
        .killTmuxWindow(self)
    }
}

/// Kill (close) a tmux session. Returns success/failure.
public struct KillTmuxSession: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public let sessionName: String

    public init(sessionName: String) {
        self.sessionName = sessionName
    }

    public var commandType: CommandType {
        .killTmuxSession(self)
    }
}

/// Submit edited prompt content from a viewer. Returns success/failure.
public struct SubmitEditorContent: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    /// The edited content to write back to the temp file
    public let content: String

    public init(content: String) {
        self.content = content
    }

    public var commandType: CommandType {
        .submitEditorContent(self)
    }
}

/// Cancel an active editor session from a viewer. Returns success/failure.
public struct CancelEditorSession: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage

    public init() { }

    public var commandType: CommandType {
        .cancelEditorSession(self)
    }
}

// MARK: - Command Types

/// Commands that can be sent from viewer to host, with their associated data.
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
    /// Resize a tmux pane
    case resizeTmuxPane(ResizeTmuxPane)
    /// Set yolo mode (auto-approve permissions) for a pane
    case setYoloMode(SetYoloMode)
    /// Mark a session as handled (user has seen it)
    case markHandled(MarkHandled)
    /// Set a custom description for a tmux window
    case setWindowDescription(SetWindowDescription)
    /// Split a tmux pane
    case splitTmuxPane(SplitTmuxPane)
    /// Select (focus) a tmux pane
    case selectTmuxPane(SelectTmuxPane)
    /// Select (switch to) a tmux window
    case selectTmuxWindow(SelectTmuxWindow)
    /// Create a new tmux window in a session
    case createTmuxWindow(CreateTmuxWindow)
    /// Submit edited prompt content from a viewer
    case submitEditorContent(SubmitEditorContent)
    /// Cancel an active editor session from a viewer
    case cancelEditorSession(CancelEditorSession)
    /// Send raw bytes (mouse escape sequences) to a tmux pane
    case sendRawInput(SendRawInput)
    /// Check running processes in a window or session (for close confirmation)
    case checkRunningProcesses(CheckRunningProcesses)
    /// Kill (close) a tmux window
    case killTmuxWindow(KillTmuxWindow)
    /// Kill (close) a tmux session
    case killTmuxSession(KillTmuxSession)

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

    /// Create a resizeTmuxPane command
    public static func resizeTmuxPane(width: Int, height: Int) -> CommandType {
        .resizeTmuxPane(ResizeTmuxPane(width: width, height: height))
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

    /// Create a setYoloMode command
    public static func setYoloMode(enabled: Bool) -> CommandType {
        .setYoloMode(SetYoloMode(enabled: enabled))
    }

    /// Create a markHandled command
    public static var markHandled: CommandType {
        .markHandled(MarkHandled())
    }

    /// Create a setWindowDescription command
    public static func setWindowDescription(windowId: String, description: String?) -> CommandType {
        .setWindowDescription(SetWindowDescription(windowId: windowId, description: description))
    }

    /// Create a splitTmuxPane command
    public static func splitTmuxPane(direction: SplitDirection) -> CommandType {
        .splitTmuxPane(SplitTmuxPane(direction: direction))
    }

    /// Create a selectTmuxPane command
    public static var selectTmuxPane: CommandType {
        .selectTmuxPane(SelectTmuxPane())
    }

    /// Create a selectTmuxWindow command
    public static var selectTmuxWindow: CommandType {
        .selectTmuxWindow(SelectTmuxWindow())
    }

    /// Create a createTmuxWindow command
    public static func createTmuxWindow(sessionName: String, workingDirectory: String? = nil) -> CommandType {
        .createTmuxWindow(CreateTmuxWindow(sessionName: sessionName, workingDirectory: workingDirectory))
    }

    /// Create a submitEditorContent command
    public static func submitEditorContent(content: String) -> CommandType {
        .submitEditorContent(SubmitEditorContent(content: content))
    }

    /// Create a cancelEditorSession command
    public static var cancelEditorSession: CommandType {
        .cancelEditorSession(CancelEditorSession())
    }

    /// Create a sendRawInput command
    public static func sendRawInput(data: Data) -> CommandType {
        .sendRawInput(SendRawInput(data: data))
    }

    /// Create a checkRunningProcesses command
    public static func checkRunningProcesses(target: CheckRunningProcesses.Target) -> CommandType {
        .checkRunningProcesses(CheckRunningProcesses(target: target))
    }

    /// Create a killTmuxWindow command
    public static func killTmuxWindow(windowId: String) -> CommandType {
        .killTmuxWindow(KillTmuxWindow(windowId: windowId))
    }

    /// Create a killTmuxSession command
    public static func killTmuxSession(sessionName: String) -> CommandType {
        .killTmuxSession(KillTmuxSession(sessionName: sessionName))
    }
}

// MARK: - Response Requirements

public extension CommandType {
    /// Whether the host should send a `CommandResponseMessage` after executing.
    /// Most commands require a response; high-frequency fire-and-forget commands
    /// (e.g. keystrokes) return `false` to avoid wasting bandwidth.
    var requiresResponse: Bool {
        switch self {
        case .sendKeystroke,
             .sendRawInput:
            false
        default:
            true
        }
    }
}

// MARK: - Command Message

/// A command sent from viewer to host via the relay server
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

/// Info about a running process, sent from host to viewer for close confirmation.
public struct RunningProcessInfo: Codable, Sendable, Equatable {
    public let paneIndex: Int
    public let name: String
    public let isForeground: Bool

    public init(paneIndex: Int, name: String, isForeground: Bool) {
        self.paneIndex = paneIndex
        self.name = name
        self.isForeground = isForeground
    }
}

/// Response to a command execution
public struct CommandResponseMessage: Codable, Sendable {
    public let commandId: UUID
    public let success: Bool
    public let error: String?
    /// Optional pane ID returned by commands that create or affect panes
    public let paneId: String?
    /// Running processes returned by `checkRunningProcesses` command
    public let runningProcesses: [RunningProcessInfo]?

    public init(
        commandId: UUID,
        success: Bool,
        error: String? = nil,
        paneId: String? = nil,
        runningProcesses: [RunningProcessInfo]? = nil
    ) {
        self.commandId = commandId
        self.success = success
        self.error = error
        self.paneId = paneId
        self.runningProcesses = runningProcesses
    }

    public static func success(for commandId: UUID, paneId: String? = nil) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: true, paneId: paneId)
    }

    public static func success(
        for commandId: UUID,
        runningProcesses: [RunningProcessInfo]
    ) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: true, runningProcesses: runningProcesses)
    }

    public static func failure(for commandId: UUID, error: String) -> CommandResponseMessage {
        CommandResponseMessage(commandId: commandId, success: false, error: error)
    }
}
